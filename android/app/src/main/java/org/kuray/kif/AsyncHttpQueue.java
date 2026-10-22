package org.kuray.kif;

import java.net.SocketTimeoutException;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Function;
import java.util.function.LongSupplier;

/** Bounded native-client mailbox. Start, poll and cancel never wait for network IO. */
final class AsyncHttpQueue implements AutoCloseable {
    interface Operation {
        byte[] execute(long deadlineMillis) throws Exception;
        /** Must return promptly; any blocking socket disconnect belongs on another executor. */
        void cancel();
    }

    private static final int CAPACITY = 4;
    private static final long RETENTION_MILLIS = 30000;
    private final ConcurrentMap<Long, Pending> requests = new ConcurrentHashMap<>();
    private final AtomicLong sequence = new AtomicLong();
    private final Object admission = new Object();
    private final LongSupplier clock;
    private final Function<Exception, byte[]> failure;
    private final ThreadPoolExecutor workers = new ThreadPoolExecutor(2, 2, 30, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(2), runnable -> daemon(runnable, "KIF-HTTPS-Async"), new ThreadPoolExecutor.AbortPolicy());
    private final ScheduledThreadPoolExecutor timer = new ScheduledThreadPoolExecutor(1,
        runnable -> daemon(runnable, "KIF-HTTPS-Deadline"));

    AsyncHttpQueue(LongSupplier clock, Function<Exception, byte[]> failure) {
        this.clock = clock;
        this.failure = failure;
        timer.setRemoveOnCancelPolicy(true);
    }

    private static Thread daemon(Runnable runnable, String name) {
        Thread thread = new Thread(runnable, name);
        thread.setDaemon(true);
        return thread;
    }

    private final class Pending {
        final Operation operation;
        final long end;
        final AtomicBoolean stopped = new AtomicBoolean();
        final AtomicReference<Future<?>> job = new AtomicReference<>();
        final AtomicReference<ScheduledFuture<?>> alarm = new AtomicReference<>();
        volatile byte[] result;
        volatile long completedAt;

        Pending(Operation operation, int timeoutMillis) {
            this.operation = operation;
            end = clock.getAsLong() + timeoutMillis;
        }

        boolean complete(byte[] response) {
            synchronized (this) {
                if (result != null || stopped.get()) return false;
                completedAt = clock.getAsLong();
                result = Objects.requireNonNull(response);
            }
            ScheduledFuture<?> timeout = alarm.get();
            if (timeout != null) timeout.cancel(false);
            return true;
        }

        void stop() {
            if (!stopped.compareAndSet(false, true)) return;
            Future<?> running = job.get();
            if (running != null) {
                running.cancel(true);
                if (running instanceof Runnable) workers.remove((Runnable)running);
            }
            ScheduledFuture<?> timeout = alarm.get();
            if (timeout != null) timeout.cancel(false);
            operation.cancel();
        }

        void expire() {
            if (complete(failure.apply(new SocketTimeoutException("HTTP total deadline")))) stop();
        }
    }

    long start(Operation operation, int timeoutMillis) {
        if (timeoutMillis < 1 || timeoutMillis > 20000) throw new IllegalArgumentException("Invalid request timeout");
        reap();
        final Pending pending = new Pending(operation, timeoutMillis);
        final long id;
        synchronized (admission) {
            if (requests.size() >= CAPACITY) return 0;
            id = sequence.incrementAndGet();
            if (id <= 0) throw new IllegalStateException("Request ID space exhausted");
            requests.put(id, pending);
        }
        try {
            Future<?> job = workers.submit(() -> {
                try {
                    pending.complete(operation.execute(pending.end));
                } catch (Exception error) {
                    pending.complete(failure.apply(error));
                }
            });
            pending.job.set(job);
            if (pending.stopped.get()) {
                job.cancel(true);
                if (job instanceof Runnable) workers.remove((Runnable)job);
            }
            ScheduledFuture<?> alarm = timer.schedule(pending::expire,
                Math.max(0, pending.end - clock.getAsLong()), TimeUnit.MILLISECONDS);
            pending.alarm.set(alarm);
            if (pending.result != null || pending.stopped.get()) alarm.cancel(false);
            return id;
        } catch (RejectedExecutionException unavailable) {
            requests.remove(id, pending);
            pending.stop();
            return 0;
        }
    }

    byte[] poll(long id) {
        Pending pending = requests.get(id);
        if (pending == null) throw new IllegalStateException("Unknown request");
        byte[] response = pending.result;
        if (response == null) return null;
        if (!requests.remove(id, pending)) throw new IllegalStateException("Request already consumed");
        return response;
    }

    void cancel(long id) {
        Pending pending = requests.remove(id);
        if (pending != null) pending.stop();
    }

    void cancelAll() {
        for (Long id : requests.keySet()) cancel(id);
    }

    private void reap() {
        long now = clock.getAsLong();
        for (Map.Entry<Long, Pending> entry : requests.entrySet()) {
            Pending pending = entry.getValue();
            if (pending.result == null && now >= pending.end) pending.expire();
            if (pending.result != null && now - pending.completedAt >= RETENTION_MILLIS && requests.remove(entry.getKey(), pending)) pending.stop();
        }
    }

    @Override public void close() {
        cancelAll();
        workers.shutdownNow();
        timer.shutdownNow();
    }
}
