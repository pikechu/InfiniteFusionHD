package org.kuray.kif;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.util.SparseArray;
import android.util.SparseIntArray;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;

/** Translucent controls drawn over the game without reserving any surface space. */
public final class TouchControlsView extends View {
    public interface Listener {
        void onKey(int keyCode, boolean down);
        void onMenu();
    }

    public static final float MIN_SCALE = 0.65f;
    public static final float MAX_SCALE = 1.50f;
    private static final int NONE = 0;
    private static final int DPAD = 1;
    private static final int CONFIRM = 2;
    private static final int BACK = 3;
    private static final int MENU = 4;
    private static final int RUN = 5;

    private static final class Pointer {
        final int control;
        int key;
        boolean inside = true;
        Pointer(int control) { this.control = control; }
    }

    private final Listener listener;
    private final float density;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path cross = new Path();
    private final Path triangle = new Path();
    private final RectF dpad = new RectF();
    private final RectF confirm = new RectF();
    private final RectF back = new RectF();
    private final RectF run = new RectF();
    private final RectF menu = new RectF();
    private final RectF scratch = new RectF();
    private final SparseArray<Pointer> pointers = new SparseArray<>();
    // Separate fingers may hold the same control. Emit only the first down and final up.
    private final SparseIntArray keyReferences = new SparseIntArray();
    private float scale = 1.0f;
    private float unit;
    private boolean handlingGesture;

    public TouchControlsView(Context context, Listener listener) {
        super(context);
        if (listener == null) throw new IllegalArgumentException("A touch control listener is required");
        this.listener = listener;
        density = getResources().getDisplayMetrics().density;
        setFocusable(false);
        setContentDescription("游戏虚拟按键：方向、确认、返回、奔跑；右上角更多按键与设置");
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_YES);
    }

    /** The caller stores this preference; small screens can further limit the effective size. */
    public void setScale(float requestedScale) {
        if (Float.isNaN(requestedScale) || Float.isInfinite(requestedScale)) requestedScale = 1.0f;
        float next = Math.max(MIN_SCALE, Math.min(MAX_SCALE, requestedScale));
        if (scale == next) return;
        resetTouches();
        scale = next;
        updateGeometry(getWidth(), getHeight());
        invalidate();
    }

    public float getScale() { return scale; }

    /** Pixel bounds are shared by drawing, hit testing, and UI regression probes. */
    public RectF getDpadBounds() { return new RectF(dpad); }
    public RectF getConfirmBounds() { return new RectF(confirm); }
    public RectF getBackBounds() { return new RectF(back); }
    public RectF getRunBounds() { return new RectF(run); }
    public RectF getMenuBounds() { return new RectF(menu); }

    @Override protected void onSizeChanged(int width, int height, int oldWidth, int oldHeight) {
        super.onSizeChanged(width, height, oldWidth, oldHeight);
        resetTouches();
        updateGeometry(width, height);
    }

    private void updateGeometry(int width, int height) {
        float edge = 16.0f * density;
        // The two thumb clusters stay separate and below the utility menu even at 150%.
        float widthLimit = Math.max(0, width - 2 * edge - 16 * density) / 296.0f;
        float heightLimit = Math.max(0, height - 2 * edge - 48 * density) / 160.0f;
        unit = Math.max(0, Math.min(density * scale, Math.min(widthLimit, heightLimit)));
        dpad.set(edge, height - edge - 144 * unit, edge + 144 * unit, height - edge);
        float confirmX = width - edge - 36 * unit;
        float confirmY = height - edge - 124 * unit;
        confirm.set(confirmX - 36 * unit, confirmY - 36 * unit,
                confirmX + 36 * unit, confirmY + 36 * unit);
        float backX = width - edge - 120 * unit;
        float backY = height - edge - 32 * unit;
        back.set(backX - 32 * unit, backY - 32 * unit,
                backX + 32 * unit, backY + 32 * unit);
        float runX = width - edge - 32 * unit;
        float runY = height - edge - 32 * unit;
        run.set(runX - 32 * unit, runY - 32 * unit,
                runX + 32 * unit, runY + 32 * unit);
        float menuSize = Math.min(48 * density, Math.min(width, height));
        float menuEdge = Math.min(12 * density, Math.max(0, (Math.min(width, height) - menuSize) / 2));
        menu.set(width - menuEdge - menuSize, menuEdge, width - menuEdge, menuEdge + menuSize);
        cross.reset();
        if (unit <= 0) return;
        float arm = 24 * unit;
        scratch.set(dpad.centerX() - arm, dpad.top, dpad.centerX() + arm, dpad.bottom);
        cross.addRoundRect(scratch, 7 * unit, 7 * unit, Path.Direction.CW);
        Path horizontal = new Path();
        scratch.set(dpad.left, dpad.centerY() - arm, dpad.right, dpad.centerY() + arm);
        horizontal.addRoundRect(scratch, 7 * unit, 7 * unit, Path.Direction.CW);
        cross.op(horizontal, Path.Op.UNION);
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if (unit > 0) {
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(Color.argb(51, 15, 20, 27));
            canvas.drawPath(cross, paint);
            drawDirectionHighlight(canvas, KeyEvent.KEYCODE_DPAD_UP, 1, 0);
            drawDirectionHighlight(canvas, KeyEvent.KEYCODE_DPAD_LEFT, 0, 1);
            drawDirectionHighlight(canvas, KeyEvent.KEYCODE_DPAD_RIGHT, 2, 1);
            drawDirectionHighlight(canvas, KeyEvent.KEYCODE_DPAD_DOWN, 1, 2);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(1.5f * unit);
            paint.setColor(Color.argb(155, 255, 255, 255));
            canvas.drawPath(cross, paint);
            drawArrow(canvas, dpad.centerX(), dpad.top + 24 * unit, 0);
            drawArrow(canvas, dpad.left + 24 * unit, dpad.centerY(), -90);
            drawArrow(canvas, dpad.right - 24 * unit, dpad.centerY(), 90);
            drawArrow(canvas, dpad.centerX(), dpad.bottom - 24 * unit, 180);
            drawAction(canvas, confirm, "确认", KeyEvent.KEYCODE_C, 18 * unit);
            drawAction(canvas, back, "返回", KeyEvent.KEYCODE_X, 16 * unit);
            drawAction(canvas, run, "奔跑", KeyEvent.KEYCODE_Z, 16 * unit);
        }
        boolean menuPressed = false;
        for (int i = 0; i < pointers.size(); i++) {
            Pointer pointer = pointers.valueAt(i);
            menuPressed |= pointer.control == MENU && pointer.inside;
        }
        float menuRadius = menu.width() * 0.43f;
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(menuPressed ? Color.argb(110, 255, 255, 255) : Color.argb(51, 15, 20, 27));
        canvas.drawCircle(menu.centerX(), menu.centerY(), menuRadius, paint);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(1.25f * density);
        paint.setColor(Color.argb(menuPressed ? 230 : 155, 255, 255, 255));
        canvas.drawCircle(menu.centerX(), menu.centerY(), menuRadius, paint);
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.argb(200, 255, 255, 255));
        for (int i = -1; i <= 1; i++) {
            canvas.drawCircle(menu.centerX() + i * menu.width() * 0.145f,
                    menu.centerY(), menu.width() * 0.04f, paint);
        }
    }

    private void drawDirectionHighlight(Canvas canvas, int key, int column, int row) {
        if (keyReferences.get(key) == 0) return;
        float cell = 48 * unit;
        scratch.set(dpad.left + column * cell + 2 * unit, dpad.top + row * cell + 2 * unit,
                dpad.left + (column + 1) * cell - 2 * unit, dpad.top + (row + 1) * cell - 2 * unit);
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.argb(105, 255, 255, 255));
        canvas.drawRoundRect(scratch, 5 * unit, 5 * unit, paint);
    }

    private void drawArrow(Canvas canvas, float x, float y, float rotation) {
        int saved = canvas.save();
        canvas.rotate(rotation, x, y);
        triangle.reset();
        triangle.moveTo(x, y - 7 * unit);
        triangle.lineTo(x + 8 * unit, y + 5 * unit);
        triangle.lineTo(x - 8 * unit, y + 5 * unit);
        triangle.close();
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.argb(190, 255, 255, 255));
        canvas.drawPath(triangle, paint);
        canvas.restoreToCount(saved);
    }

    private void drawAction(Canvas canvas, RectF bounds, String label, int key, float textSize) {
        boolean pressed = keyReferences.get(key) > 0;
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(pressed ? Color.argb(105, 255, 255, 255) : Color.argb(51, 15, 20, 27));
        canvas.drawOval(bounds, paint);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(1.5f * unit);
        paint.setColor(Color.argb(pressed ? 230 : 155, 255, 255, 255));
        canvas.drawOval(bounds, paint);
        paint.setStyle(Paint.Style.FILL);
        paint.setTypeface(Typeface.DEFAULT_BOLD);
        paint.setTextSize(textSize);
        paint.setTextAlign(Paint.Align.CENTER);
        paint.setColor(Color.argb(pressed ? 255 : 200, 255, 255, 255));
        float baseline = bounds.centerY() - (paint.ascent() + paint.descent()) / 2;
        canvas.drawText(label, bounds.centerX(), baseline, paint);
    }

    private boolean inCircle(RectF bounds, float x, float y, float extra) {
        float radius = bounds.width() / 2 + extra;
        float dx = x - bounds.centerX(), dy = y - bounds.centerY();
        return dx * dx + dy * dy <= radius * radius;
    }

    private int hitControl(float x, float y) {
        if (menu.contains(x, y)) return MENU;
        if (unit <= 0) return NONE;
        if (inCircle(confirm, x, y, 6 * density)) return CONFIRM;
        if (inCircle(back, x, y, 6 * density)) return BACK;
        if (inCircle(run, x, y, 6 * density)) return RUN;
        if (x >= dpad.left - 6 * density && x <= dpad.right + 6 * density
                && y >= dpad.top - 6 * density && y <= dpad.bottom + 6 * density) return DPAD;
        return NONE;
    }

    private int dpadKey(float x, float y) {
        float dx = x - dpad.centerX(), dy = y - dpad.centerY();
        // A neutral center prevents accidental directions while repositioning the thumb.
        if (Math.max(Math.abs(dx), Math.abs(dy)) < 16 * unit) return 0;
        if (x < dpad.left - 24 * density || x > dpad.right + 24 * density
                || y < dpad.top - 24 * density || y > dpad.bottom + 24 * density) return 0;
        if (Math.abs(dx) > Math.abs(dy)) return dx < 0 ? KeyEvent.KEYCODE_DPAD_LEFT : KeyEvent.KEYCODE_DPAD_RIGHT;
        return dy < 0 ? KeyEvent.KEYCODE_DPAD_UP : KeyEvent.KEYCODE_DPAD_DOWN;
    }

    private void changeKey(Pointer pointer, int key) {
        if (pointer.key == key) return;
        if (pointer.key != 0) {
            int previous = pointer.key;
            int references = keyReferences.get(previous) - 1;
            if (references <= 0) {
                keyReferences.delete(previous);
                listener.onKey(previous, false);
            } else keyReferences.put(previous, references);
        }
        pointer.key = key;
        if (key != 0) {
            int references = keyReferences.get(key);
            keyReferences.put(key, references + 1);
            if (references == 0) listener.onKey(key, true);
        }
    }

    private void updatePointer(Pointer pointer, float x, float y) {
        int key = 0;
        if (pointer.control == DPAD) key = dpadKey(x, y);
        else if (pointer.control == CONFIRM && inCircle(confirm, x, y, 8 * density)) key = KeyEvent.KEYCODE_C;
        else if (pointer.control == BACK && inCircle(back, x, y, 8 * density)) key = KeyEvent.KEYCODE_X;
        else if (pointer.control == RUN && inCircle(run, x, y, 8 * density)) key = KeyEvent.KEYCODE_Z;
        pointer.inside = pointer.control != MENU || menu.contains(x, y);
        changeKey(pointer, key);
    }

    @Override public boolean onTouchEvent(MotionEvent event) {
        int action = event.getActionMasked();
        int index = event.getActionIndex();
        if (action == MotionEvent.ACTION_DOWN) {
            resetTouches();
            int control = hitControl(event.getX(index), event.getY(index));
            if (control == NONE) return false; // Let the game receive touches away from controls.
            handlingGesture = true;
            if (getParent() != null) getParent().requestDisallowInterceptTouchEvent(true);
            Pointer pointer = new Pointer(control);
            pointers.put(event.getPointerId(index), pointer);
            updatePointer(pointer, event.getX(index), event.getY(index));
        } else if (!handlingGesture) return false;
        else if (action == MotionEvent.ACTION_POINTER_DOWN) {
            int control = hitControl(event.getX(index), event.getY(index));
            if (control != NONE) {
                Pointer pointer = new Pointer(control);
                pointers.put(event.getPointerId(index), pointer);
                updatePointer(pointer, event.getX(index), event.getY(index));
            }
        } else if (action == MotionEvent.ACTION_MOVE) {
            for (int i = 0; i < event.getPointerCount(); i++) {
                Pointer pointer = pointers.get(event.getPointerId(i));
                if (pointer != null) updatePointer(pointer, event.getX(i), event.getY(i));
            }
        } else if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_POINTER_UP) {
            Pointer pointer = pointers.get(event.getPointerId(index));
            boolean openMenu = pointer != null && pointer.control == MENU
                    && menu.contains(event.getX(index), event.getY(index));
            if (pointer != null) {
                changeKey(pointer, 0);
                pointers.remove(event.getPointerId(index));
            }
            if (action == MotionEvent.ACTION_UP) {
                resetTouches();
                performClick();
            }
            // Release every held game key before a modal menu can take over the gesture.
            if (openMenu) {
                resetTouches();
                listener.onMenu();
            }
        } else if (action == MotionEvent.ACTION_CANCEL) resetTouches();
        invalidate();
        return true;
    }

    /** Release bridge keys before pause, dialogs, layout changes, or detaching the view. */
    public void resetTouches() {
        pointers.clear();
        for (int i = 0; i < keyReferences.size(); i++) listener.onKey(keyReferences.keyAt(i), false);
        keyReferences.clear();
        handlingGesture = false;
        if (getParent() != null) getParent().requestDisallowInterceptTouchEvent(false);
        invalidate();
    }

    @Override public boolean performClick() { super.performClick(); return true; }

    @Override public void onWindowFocusChanged(boolean hasWindowFocus) {
        if (!hasWindowFocus) resetTouches();
        super.onWindowFocusChanged(hasWindowFocus);
    }

    @Override protected void onDetachedFromWindow() {
        resetTouches();
        super.onDetachedFromWindow();
    }
}
