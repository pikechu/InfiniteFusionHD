package org.kuray.kif;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/** Real workers and deadline scheduling, with controlled slow/uninterruptible operations. */
public final class AsyncHttpQueueHostTest {
    private static int checks;
    private static byte[] bytes(String text) { return text.getBytes(StandardCharsets.UTF_8); }
    private static long now() { return TimeUnit.NANOSECONDS.toMillis(System.nanoTime()); }
    private static void check(boolean condition, String description) {
        if (!condition) throw new AssertionError(description);
        checks++;
    }
    private static byte[] await(AsyncHttpQueue queue, long id) throws Exception {
        long end = now() + 2000;
        byte[] response;
        while ((response = queue.poll(id)) == null) {
            if (now() > end) throw new AssertionError("Request never completed");
            Thread.sleep(1);
        }
        return response;
    }
    private static final class Held implements AsyncHttpQueue.Operation {
        final CountDownLatch entered = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final AtomicBoolean cancelled = new AtomicBoolean();
        final AtomicBoolean executed = new AtomicBoolean();
        @Override public byte[] execute(long end) {
            executed.set(true);
            entered.countDown();
            // Model DNS/native IO that finishes later despite interruption.
            boolean released = false;
            while (!released) {
                try { release.await(); released = true; }
                catch (InterruptedException ignored) { }
            }
            return bytes("late-success");
        }
        @Override public void cancel() { cancelled.set(true); }
    }

    public static void main(String[] args) throws Exception {
        List<Held> held = new ArrayList<>();
        try (AsyncHttpQueue queue = new AsyncHttpQueue(AsyncHttpQueueHostTest::now,
                error -> bytes(error.getClass().getSimpleName()))) {
            Held slow = new Held(); held.add(slow);
            long first = queue.start(slow, 2000);
            check(first > 0 && slow.entered.await(1, TimeUnit.SECONDS), "slow network starts on worker");
            for (int frame = 0; frame < 200; frame++) check(queue.poll(first) == null, "game can poll while backend is held");
            slow.release.countDown();
            check(new String(await(queue, first), StandardCharsets.UTF_8).equals("late-success"), "completed response delivered");
            boolean consumed = false;
            try { queue.poll(first); } catch (IllegalStateException expected) { consumed = true; }
            check(consumed, "response consumed only once");

            Held timeout = new Held(); held.add(timeout);
            long expiring = queue.start(timeout, 60);
            check(timeout.entered.await(1, TimeUnit.SECONDS), "timeout fixture really entered blocking IO");
            check(new String(await(queue, expiring), StandardCharsets.UTF_8).equals("SocketTimeoutException"), "deadline returns even when backend ignores interruption");
            check(timeout.cancelled.get(), "timeout asks backend to disconnect");
            timeout.release.countDown();

            Held one = new Held(), two = new Held(), queued = new Held(), fourth = new Held();
            held.add(one); held.add(two); held.add(queued); held.add(fourth);
            long idOne = queue.start(one, 2000), idTwo = queue.start(two, 2000);
            check(one.entered.await(1, TimeUnit.SECONDS) && two.entered.await(1, TimeUnit.SECONDS), "two workers are occupied");
            long idQueued = queue.start(queued, 80), idFourth = queue.start(fourth, 2000);
            check(idQueued > 0 && idFourth > 0 && queue.start(new Held(), 2000) == 0, "pending and completed requests have bounded capacity");
            check(new String(await(queue, idQueued), StandardCharsets.UTF_8).equals("SocketTimeoutException") && !queued.executed.get(), "queued time counts against deadline");
            queue.cancel(idFourth);
            check(fourth.cancelled.get(), "explicit cancel notifies queued operation");
            Held replacement = new Held(); held.add(replacement);
            long idReplacement = queue.start(replacement, 2000);
            check(idReplacement > idFourth, "canceled queued requests release executor capacity and IDs never repeat");
            queue.cancel(idOne); queue.cancel(idTwo); queue.cancel(idReplacement);
            check(one.cancelled.get() && two.cancelled.get(), "running requests can be canceled without waiting for their latch");
            one.release.countDown(); two.release.countDown();
        } finally {
            for (Held operation : held) operation.release.countDown();
        }
        AtomicLong clock = new AtomicLong(1);
        try (AsyncHttpQueue queue = new AsyncHttpQueue(clock::get, error -> bytes("failed"))) {
            AsyncHttpQueue.Operation instant = new AsyncHttpQueue.Operation() {
                public byte[] execute(long end) { return bytes("ok"); }
                public void cancel() { }
            };
            for (int index = 0; index < 4; index++) {
                long id = queue.start(instant, 2000);
                check(id > 0, "bounded abandoned response admitted");
                Thread.sleep(10);
            }
            check(queue.start(instant, 2000) == 0, "unconsumed response bytes remain bounded");
            clock.set(31002);
            long reclaimed = queue.start(instant, 2000);
            check(reclaimed > 0 && new String(await(queue, reclaimed), StandardCharsets.UTF_8).equals("ok"), "expired abandoned responses are reclaimed");
        }
        System.out.println("ASYNC_HTTP_QUEUE_HOST_PASS checks=" + checks);
    }
}
