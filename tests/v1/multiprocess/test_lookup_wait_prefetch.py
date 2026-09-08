# SPDX-License-Identifier: Apache-2.0
"""Unit tests for the ``WAIT_PREFETCH_STATUS`` request handler path.

The prefetch-controller tests cover the condition-variable wait in isolation;
these cover the ``LookupModule`` handler that ``WAIT_PREFETCH_STATUS`` dispatches
to, i.e. the ``wait_prefetch_status -> query_prefetch_status`` path: count
computation, event emission, and exactly-once job consumption. The storage
manager is mocked, so no GPU or native bitmap is needed.
"""

# Standard
from unittest import mock
import threading

# Third Party
import pytest

# First Party
from lmcache.lmcache_native import Bitmap
from lmcache.v1.distributed.api import PrefetchHandle
from lmcache.v1.multiprocess.modules.lookup import LookupModule, _PrefetchJob


def _make_ctx(wait_result=True, found=None):
    storage_manager = mock.Mock()
    storage_manager.wait_prefetch_status.return_value = wait_result
    storage_manager.query_prefetch_status.return_value = found
    ctx = mock.Mock()
    ctx.storage_manager = storage_manager
    ctx.event_bus = mock.Mock()
    ctx.chunk_size = 256
    return ctx


def _make_module(ctx):
    # Bypass __init__ (which wires up otel metrics needing a full context); the
    # handler methods only touch _ctx, _prefetch_jobs, and _prefetch_job_lock.
    module = object.__new__(LookupModule)
    module._ctx = ctx
    module._prefetch_jobs = {}
    module._prefetch_job_lock = threading.Lock()
    module._abandoned_jobs = []
    module._abandoned_jobs_cv = threading.Condition()
    module._cleanup_stop = False
    module._cleanup_thread = threading.Thread(
        target=module._run_abandoned_prefetch_cleanup, daemon=True
    )
    module._cleanup_thread.start()
    return module


def test_wait_prefetch_status_returns_count_and_consumes_job():
    # 8 keys = 4 chunks with world_size=2, 1 object group (stride=2).
    # All 8 bits set -> fold_unfold_ranked returns hit_length=4.
    num_keys = 8
    found = Bitmap(num_keys, num_keys)
    handle = PrefetchHandle(
        prefetch_request_id=0,
        external_request_id="req",
        l1_found_indices=(),
        l1_hit_chunks=0,
        total_requested_keys=num_keys,
        submit_time=0.0,
    )
    ctx = _make_ctx(wait_result=True, found=found)
    module = _make_module(ctx)
    module._prefetch_jobs["req"] = _PrefetchJob(
        handle=handle,
        world_size=2,
        request_id="req",
        requested_tokens=512,
    )

    assert module.wait_prefetch_status("req", timeout=1.0) == 4
    ctx.storage_manager.wait_prefetch_status.assert_called_once_with(handle, 1.0)
    ctx.event_bus.publish.assert_called_once()
    # Exactly-once: the job is removed after a non-None result.
    assert "req" not in module._prefetch_jobs
    # The hit length is recorded on the session so free_lookup_locks can
    # later reconstruct which keys the prefetch read-locked.
    ctx.session_manager.get_or_create.assert_called_once_with("req")
    session = ctx.session_manager.get_or_create.return_value
    session.record_prefetch_result.assert_called_once_with(4, (0,))


def test_wait_prefetch_status_timeout_returns_none_and_keeps_job():
    ctx = _make_ctx(wait_result=False)
    module = _make_module(ctx)
    job = _PrefetchJob(
        handle=mock.sentinel.handle,
        world_size=1,
        request_id="req",
        requested_tokens=0,
    )
    module._prefetch_jobs["req"] = job

    assert module.wait_prefetch_status("req", timeout=0.5) is None
    ctx.storage_manager.query_prefetch_status.assert_not_called()
    # Job is kept so a later wait/query can still resolve it.
    assert module._prefetch_jobs["req"] is job


def test_wait_prefetch_status_unknown_request_returns_zero():
    module = _make_module(_make_ctx())
    assert module.wait_prefetch_status("missing", timeout=1.0) == 0


def _cleanup_job(request_id: str = "req") -> _PrefetchJob:
    handle = PrefetchHandle(
        prefetch_request_id=7,
        external_request_id=request_id,
        l1_found_indices=(),
        l1_hit_chunks=0,
        total_requested_keys=3,
        submit_time=0.0,
    )
    return _PrefetchJob(
        handle=handle,
        world_size=1,
        request_id=request_id,
        requested_tokens=768,
        keys=("key-0", "key-1", "key-2"),
        num_kv_readers=2,
    )


def test_status_query_exception_releases_job_claim():
    ctx = _make_ctx()
    ctx.storage_manager.query_prefetch_status.side_effect = RuntimeError("boom")
    module = _make_module(ctx)
    job = _cleanup_job()
    module._prefetch_jobs["req"] = job

    with pytest.raises(RuntimeError, match="boom"):
        module.query_prefetch_status("req")

    assert job.status_claimed is False
    assert module._take_prefetch_job("req") is job
    module.close()


def test_end_session_cleans_prefetch_that_finishes_later():
    completed = threading.Event()
    allow_completion = threading.Event()
    found = Bitmap(3)
    found.set(0)
    found.set(2)
    ctx = _make_ctx(found=found)

    def query_after_completion(handle):
        if not allow_completion.is_set():
            return None
        completed.set()
        return found

    ctx.storage_manager.query_prefetch_status.side_effect = query_after_completion
    ctx.session_manager.remove.return_value = None
    module = _make_module(ctx)
    job = _cleanup_job()
    module._prefetch_jobs["req"] = job

    module.end_session("req")
    assert "req" not in module._prefetch_jobs
    ctx.storage_manager.finish_read_prefetched.assert_not_called()

    allow_completion.set()
    assert completed.wait(1.0)
    module.close()
    ctx.storage_manager.finish_read_prefetched.assert_called_once_with(
        ["key-0", "key-2"], read_locks=2
    )


def test_end_session_cleans_already_completed_prefetch():
    found = Bitmap(3)
    found.set(1)
    ctx = _make_ctx(wait_result=True, found=found)
    ctx.session_manager.remove.return_value = None
    module = _make_module(ctx)
    module._prefetch_jobs["req"] = _cleanup_job()

    module.end_session("req")
    module.close()

    ctx.storage_manager.finish_read_prefetched.assert_called_once_with(
        ["key-1"], read_locks=2
    )
    assert "req" not in module._prefetch_jobs


def test_status_query_and_end_session_have_single_job_owner():
    found = Bitmap(3, 3)
    query_started = threading.Event()
    allow_query = threading.Event()
    ctx = _make_ctx(found=found)
    ctx.session_manager.remove.return_value = None

    def blocking_query(handle):
        query_started.set()
        assert allow_query.wait(1.0)
        return found

    ctx.storage_manager.query_prefetch_status.side_effect = blocking_query
    module = _make_module(ctx)
    module._prefetch_jobs["req"] = _cleanup_job()
    result: list[int | None] = []
    query_thread = threading.Thread(
        target=lambda: result.append(module.query_prefetch_status("req"))
    )
    query_thread.start()
    assert query_started.wait(1.0)

    end_thread = threading.Thread(target=lambda: module.end_session("req"))
    end_thread.start()
    assert end_thread.is_alive()

    allow_query.set()
    query_thread.join(timeout=1.0)
    end_thread.join(timeout=1.0)
    module.close()

    assert result == [3]
    ctx.storage_manager.finish_read_prefetched.assert_not_called()


def test_status_consumption_prevents_end_session_double_release():
    found = Bitmap(3, 3)
    ctx = _make_ctx(wait_result=True, found=found)
    ctx.session_manager.remove.return_value = None
    module = _make_module(ctx)
    module._prefetch_jobs["req"] = _cleanup_job()

    assert module.wait_prefetch_status("req", timeout=1.0) == 3
    module.end_session("req")
    module.close()

    ctx.storage_manager.finish_read_prefetched.assert_not_called()
