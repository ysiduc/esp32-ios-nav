package com.esp32nav.app.mobile_app

import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.math.abs
import kotlin.math.hypot

class TurnArrowClassifierTest {

    private companion object {
        const val SIZE = 48
        const val TRANSPARENT = 0x00000000
        const val GREEN_BADGE = 0xFF0B6B5A.toInt()
        const val WHITE = 0xFFFFFFFF.toInt()
        const val DARK_BG = 0xFF1C1C1E.toInt()
    }

    private fun newGreenCircleCanvas(): IntArray {
        val px = IntArray(SIZE * SIZE) { TRANSPARENT }
        val cx = (SIZE - 1) / 2.0
        val cy = (SIZE - 1) / 2.0
        val radius = SIZE * 0.47
        for (y in 0 until SIZE) {
            for (x in 0 until SIZE) {
                if (hypot(x - cx, y - cy) <= radius) {
                    px[y * SIZE + x] = GREEN_BADGE
                }
            }
        }
        return px
    }

    private fun newTransparentCanvas(): IntArray = IntArray(SIZE * SIZE) { TRANSPARENT }

    private fun drawThickSegment(
        px: IntArray,
        x0: Double,
        y0: Double,
        x1: Double,
        y1: Double,
        halfThickness: Double = 2.4,
        color: Int = WHITE
    ) {
        val dx = x1 - x0
        val dy = y1 - y0
        val lenSq = dx * dx + dy * dy
        for (y in 0 until SIZE) {
            for (x in 0 until SIZE) {
                val t = if (lenSq > 0.0) (((x - x0) * dx + (y - y0) * dy) / lenSq).coerceIn(0.0, 1.0) else 0.0
                val projX = x0 + t * dx
                val projY = y0 + t * dy
                if (hypot(x - projX, y - projY) <= halfThickness) {
                    px[y * SIZE + x] = color
                }
            }
        }
    }

    private fun drawRing(
        px: IntArray,
        cx: Double,
        cy: Double,
        rInner: Double,
        rOuter: Double,
        color: Int = WHITE
    ) {
        for (y in 0 until SIZE) {
            for (x in 0 until SIZE) {
                val d = hypot(x - cx, y - cy)
                if (d in rInner..rOuter) {
                    px[y * SIZE + x] = color
                }
            }
        }
    }

    private fun fillTriangle(
        px: IntArray,
        ax: Double,
        ay: Double,
        bx: Double,
        by: Double,
        cx: Double,
        cy: Double,
        color: Int = WHITE
    ) {
        fun sign(px0: Double, py0: Double, x1: Double, y1: Double, x2: Double, y2: Double): Double =
            (px0 - x2) * (y1 - y2) - (x1 - x2) * (py0 - y2)

        for (y in 0 until SIZE) {
            for (x in 0 until SIZE) {
                val d1 = sign(x.toDouble(), y.toDouble(), ax, ay, bx, by)
                val d2 = sign(x.toDouble(), y.toDouble(), bx, by, cx, cy)
                val d3 = sign(x.toDouble(), y.toDouble(), cx, cy, ax, ay)
                val hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0)
                val hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0)
                if (!(hasNeg && hasPos)) {
                    px[y * SIZE + x] = color
                }
            }
        }
    }

    @Test
    fun greenCircleStraightArrowClassifiesAsStraight() {
        val px = newGreenCircleCanvas()
        drawThickSegment(px, 24.0, 38.0, 24.0, 14.0)
        fillTriangle(px, 24.0, 7.0, 15.0, 18.0, 33.0, 18.0)
        assertEquals(0, TurnArrowClassifier.classifyArgbPixels(px, SIZE, SIZE))
    }

    @Test
    fun greenCircleTurnRightArrowClassifiesAsRight() {
        val px = newGreenCircleCanvas()
        drawThickSegment(px, 16.0, 38.0, 16.0, 18.0)
        drawThickSegment(px, 16.0, 18.0, 31.0, 18.0)
        fillTriangle(px, 40.0, 18.0, 28.0, 10.0, 28.0, 26.0)
        assertEquals(2, TurnArrowClassifier.classifyArgbPixels(px, SIZE, SIZE))
    }

    @Test
    fun greenCircleTurnLeftArrowClassifiesAsLeft() {
        val px = newGreenCircleCanvas()
        drawThickSegment(px, 32.0, 38.0, 32.0, 18.0)
        drawThickSegment(px, 32.0, 18.0, 17.0, 18.0)
        fillTriangle(px, 8.0, 18.0, 20.0, 10.0, 20.0, 26.0)
        assertEquals(6, TurnArrowClassifier.classifyArgbPixels(px, SIZE, SIZE))
    }

    @Test
    fun greenCircleSlightRightAndLeftClassifyAccurately() {
        val rightPx = newGreenCircleCanvas()
        drawThickSegment(rightPx, 19.0, 39.0, 28.0, 15.0)
        fillTriangle(rightPx, 33.0, 9.0, 21.0, 13.0, 31.0, 22.0)
        assertEquals(1, TurnArrowClassifier.classifyArgbPixels(rightPx, SIZE, SIZE))

        val leftPx = newGreenCircleCanvas()
        drawThickSegment(leftPx, 29.0, 39.0, 20.0, 15.0)
        fillTriangle(leftPx, 15.0, 9.0, 27.0, 13.0, 17.0, 22.0)
        assertEquals(7, TurnArrowClassifier.classifyArgbPixels(leftPx, SIZE, SIZE))
    }

    @Test
    fun greenCircleSharpRightAndLeftClassifyAccurately() {
        val sharpRight = newGreenCircleCanvas()
        drawThickSegment(sharpRight, 15.0, 39.0, 15.0, 13.0)
        drawThickSegment(sharpRight, 15.0, 13.0, 33.0, 27.0)
        fillTriangle(sharpRight, 39.0, 32.0, 34.0, 19.0, 26.0, 31.0)
        assertEquals(3, TurnArrowClassifier.classifyArgbPixels(sharpRight, SIZE, SIZE))

        val sharpLeft = newGreenCircleCanvas()
        drawThickSegment(sharpLeft, 33.0, 39.0, 33.0, 13.0)
        drawThickSegment(sharpLeft, 33.0, 13.0, 15.0, 27.0)
        fillTriangle(sharpLeft, 9.0, 32.0, 14.0, 19.0, 22.0, 31.0)
        assertEquals(5, TurnArrowClassifier.classifyArgbPixels(sharpLeft, SIZE, SIZE))
    }

    @Test
    fun greenCircleUTurnClassifiesAsUTurn() {
        val px = newGreenCircleCanvas()
        // Right stem going up, arch over top, down-pointing head on left (matches Google Maps VN U-turn)
        drawThickSegment(px, 31.0, 39.0, 31.0, 15.0)
        drawThickSegment(px, 16.0, 13.0, 31.0, 13.0)
        drawThickSegment(px, 16.0, 15.0, 16.0, 25.0)
        fillTriangle(px, 16.0, 33.0, 9.0, 23.0, 23.0, 23.0)
        assertEquals(4, TurnArrowClassifier.classifyArgbPixels(px, SIZE, SIZE))
    }

    @Test
    fun greenCircleRoundaboutClassifiesAsRoundabout() {
        val px = newGreenCircleCanvas()
        drawRing(px, 24.0, 21.0, 6.2, 10.6)
        drawThickSegment(px, 24.0, 31.0, 24.0, 41.0)
        drawThickSegment(px, 31.0, 14.0, 37.0, 8.0)
        fillTriangle(px, 40.0, 5.0, 31.0, 7.0, 37.0, 14.0)
        assertEquals(8, TurnArrowClassifier.classifyArgbPixels(px, SIZE, SIZE))
    }

    @Test
    fun cutoutTransparentTurnLeftStillClassifiesAsLeft() {
        val px = newTransparentCanvas()
        drawThickSegment(px, 32.0, 39.0, 32.0, 17.0)
        drawThickSegment(px, 32.0, 17.0, 16.0, 17.0)
        fillTriangle(px, 7.0, 17.0, 19.0, 9.0, 19.0, 25.0)
        assertEquals(6, TurnArrowClassifier.classifyArgbPixels(px, SIZE, SIZE))
    }

    @Test
    fun darkBadgeTurnRightStillClassifiesAsRight() {
        val px = IntArray(SIZE * SIZE) { TRANSPARENT }
        for (y in 2 until SIZE - 2) {
            for (x in 2 until SIZE - 2) {
                px[y * SIZE + x] = DARK_BG
            }
        }
        drawThickSegment(px, 16.0, 38.0, 16.0, 18.0)
        drawThickSegment(px, 16.0, 18.0, 31.0, 18.0)
        fillTriangle(px, 40.0, 18.0, 28.0, 10.0, 28.0, 26.0)
        assertEquals(2, TurnArrowClassifier.classifyArgbPixels(px, SIZE, SIZE))
    }

    @Test
    fun solidCircleLogoWithoutArrowReturnsUnknownInsteadOfFalseDirection() {
        val px = newGreenCircleCanvas()
        assertEquals(-1, TurnArrowClassifier.classifyArgbPixels(px, SIZE, SIZE))
    }
}
