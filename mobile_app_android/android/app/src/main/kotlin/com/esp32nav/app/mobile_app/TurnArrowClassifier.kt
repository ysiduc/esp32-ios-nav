package com.esp32nav.app.mobile_app

import android.graphics.Bitmap
import kotlin.math.abs
import kotlin.math.atan2

/**
 * Geometric classifier for Google Maps notification turn icons -> ESP32 turnCode:
 * -1: unknown
 *  0: straight
 *  1: slight right
 *  2: turn right
 *  3: sharp right
 *  4: U-turn
 *  5: sharp left
 *  6: turn left
 *  7: slight left
 *  8: roundabout
 */
object TurnArrowClassifier {

    private const val SAMPLE_SIZE = 48

    fun classifyBitmap(bitmap: Bitmap): Int {
        if (bitmap.isRecycled || bitmap.width < 12 || bitmap.height < 12) return -1
        return try {
            val scaled = if (bitmap.width == SAMPLE_SIZE && bitmap.height == SAMPLE_SIZE) {
                bitmap
            } else {
                Bitmap.createScaledBitmap(bitmap, SAMPLE_SIZE, SAMPLE_SIZE, true)
            }
            val pixels = IntArray(SAMPLE_SIZE * SAMPLE_SIZE)
            scaled.getPixels(pixels, 0, SAMPLE_SIZE, 0, 0, SAMPLE_SIZE, SAMPLE_SIZE)
            if (scaled !== bitmap) scaled.recycle()
            classifyArgbPixels(pixels, SAMPLE_SIZE, SAMPLE_SIZE)
        } catch (_: Throwable) {
            -1
        }
    }

    /**
     * Pure pixel-array entry point (unit-testable on JVM without Android Bitmap).
     */
    fun classifyArgbPixels(pixels: IntArray, width: Int, height: Int): Int {
        if (width < 16 || height < 16 || pixels.size < width * height) return -1

        val mask = extractForegroundMask(pixels, width, height) ?: return -1
        return classifyMask(mask, width, height)
    }

    private fun extractForegroundMask(pixels: IntArray, width: Int, height: Int): BooleanArray? {
        val total = width * height
        val cornerOffsets = arrayOf(
            Pair(1, 1),
            Pair(width - 2, 1),
            Pair(1, height - 2),
            Pair(width - 2, height - 2)
        )
        var transparentCorners = 0
        for ((cx, cy) in cornerOffsets) {
            val c = pixels[cy * width + cx]
            if (((c ushr 24) and 0xFF) < 80) transparentCorners++
        }

        // Build quantized 3-bit RGB histogram across opaque pixels to discover any container badge
        // (e.g., white arrow rendered inside an opaque green circle or dark rounded shield).
        val binCounts = IntArray(512)
        val binSumR = LongArray(512)
        val binSumG = LongArray(512)
        val binSumB = LongArray(512)
        var opaqueCount = 0

        for (i in 0 until total) {
            val c = pixels[i]
            val a = (c ushr 24) and 0xFF
            if (a < 105) continue
            val r = (c ushr 16) and 0xFF
            val g = (c ushr 8) and 0xFF
            val b = c and 0xFF
            val bin = ((r ushr 5) shl 6) or ((g ushr 5) shl 3) or (b ushr 5)
            binCounts[bin]++
            binSumR[bin] += r.toLong()
            binSumG[bin] += g.toLong()
            binSumB[bin] += b.toLong()
            opaqueCount++
        }

        if (opaqueCount < 24) return null

        var domBin = 0
        var domCount = -1
        for (b in 0 until 512) {
            if (binCounts[b] > domCount) {
                domCount = binCounts[b]
                domBin = b
            }
        }
        val domR = (binSumR[domBin] / domCount.coerceAtLeast(1)).toInt()
        val domG = (binSumG[domBin] / domCount.coerceAtLeast(1)).toInt()
        val domB = (binSumB[domBin] / domCount.coerceAtLeast(1)).toInt()
        val domLum = (domR * 30 + domG * 59 + domB * 11) / 100
        val domShare = domCount.toDouble() / opaqueCount.toDouble()
        val opaqueFrac = opaqueCount.toDouble() / total.toDouble()

        // Pure cutout glyph directly on a transparent background (no enclosing circle/pill badge).
        val isCutoutGlyph = transparentCorners >= 2 && opaqueFrac in 0.03..0.44 && domShare >= 0.68
        if (isCutoutGlyph) {
            val mask = BooleanArray(total)
            var count = 0
            for (i in 0 until total) {
                if (((pixels[i] ushr 24) and 0xFF) >= 100) {
                    mask[i] = true
                    count++
                }
            }
            if (count in 24..((total * 0.55).toInt())) return mask
        }

        // Segment foreground arrow pixels against the dominant container background color.
        val thresholds = arrayOf(Pair(65, 40), Pair(42, 26))
        for ((rgbThresh, lumThresh) in thresholds) {
            val mask = BooleanArray(total)
            var count = 0
            for (i in 0 until total) {
                val c = pixels[i]
                val a = (c ushr 24) and 0xFF
                if (a < 105) continue
                val r = (c ushr 16) and 0xFF
                val g = (c ushr 8) and 0xFF
                val b = c and 0xFF
                val rgbDist = abs(r - domR) + abs(g - domG) + abs(b - domB)
                val lum = (r * 30 + g * 59 + b * 11) / 100
                if (rgbDist > rgbThresh || abs(lum - domLum) > lumThresh) {
                    mask[i] = true
                    count++
                }
            }
            if (count in 24..((total * 0.65).toInt())) {
                return mask
            }
        }

        if (transparentCorners >= 2 && opaqueFrac in 0.03..0.60) {
            val mask = BooleanArray(total)
            var count = 0
            for (i in 0 until total) {
                if (((pixels[i] ushr 24) and 0xFF) >= 90) {
                    mask[i] = true
                    count++
                }
            }
            if (count >= 24) return mask
        }
        return null
    }

    private fun countRowSeparatedRuns(
        mask: BooleanArray,
        width: Int,
        y: Int,
        minX: Int,
        maxX: Int,
        minGapPx: Int
    ): Int {
        var runs = 0
        var inRun = false
        var gapPx = 0
        for (x in minX..maxX) {
            val fg = mask[y * width + x]
            if (fg) {
                if (!inRun && (runs == 0 || gapPx >= minGapPx)) {
                    runs++
                }
                inRun = true
                gapPx = 0
            } else {
                if (inRun) gapPx = 1 else if (runs > 0) gapPx++
                inRun = false
            }
        }
        return runs
    }

    private fun classifyMask(mask: BooleanArray, width: Int, height: Int): Int {
        var minX = width
        var maxX = -1
        var minY = height
        var maxY = -1
        var fgCount = 0

        for (y in 0 until height) {
            for (x in 0 until width) {
                if (!mask[y * width + x]) continue
                fgCount++
                if (x < minX) minX = x
                if (x > maxX) maxX = x
                if (y < minY) minY = y
                if (y > maxY) maxY = y
            }
        }

        if (fgCount < 24 || maxX < minX || maxY < minY) return -1
        val boxW = maxX - minX + 1
        val boxH = maxY - minY + 1
        if (boxW < 8 || boxH < 8) return -1
        // Solid uniform shapes (e.g., filled circle/logo without interior cutouts) are not arrows
        val boxFill = fgCount.toDouble() / (boxW * boxH).toDouble()
        if (boxFill > 0.78) return -1

        var topSumX = 0.0
        var topCnt = 0
        var topPeakSumX = 0.0
        var topPeakCnt = 0
        var midSumX = 0.0
        var midCnt = 0
        var lowShaftSumX = 0.0
        var lowShaftCnt = 0
        var botSumX = 0.0
        var botCnt = 0
        var botLeftMass = 0
        var botRightMass = 0

        var topLeftArchCnt = 0
        var topLeftArchArea = 0
        var topMidArchCnt = 0
        var topMidArchArea = 0
        var topRightArchCnt = 0
        var topRightArchArea = 0
        var botRingCnt = 0
        var botRingArea = 0
        var coreCnt = 0
        var coreArea = 0

        val sectorsHit = IntArray(8)
        val normXs = DoubleArray(fgCount)
        val normYs = DoubleArray(fgCount)
        var idx = 0

        // Row-wise separated two-column counters (detects parallel U-turn legs / roundabout ring)
        val minGapPx = (boxW * 0.14).toInt().coerceAtLeast(3)
        var upperTwoRunRows = 0
        var uLeftMidCols = 0
        var uRightMidCols = 0
        var lowLeftCnt = 0
        var lowRightCnt = 0

        for (y in minY..maxY) {
            val yRel = (y - minY).toDouble() / (boxH - 1).coerceAtLeast(1)
            val runs = countRowSeparatedRuns(mask, width, y, minX, maxX, minGapPx)
            if (yRel in 0.18..0.45 && runs >= 2) {
                upperTwoRunRows++
            }
            for (x in minX..maxX) {
                val xRel = (x - minX).toDouble() / (boxW - 1).coerceAtLeast(1)
                val fg = mask[y * width + x]

                if (yRel <= 0.26) {
                    when {
                        xRel in 0.14..0.38 -> {
                            topLeftArchArea++
                            if (fg) topLeftArchCnt++
                        }
                        xRel in 0.39..0.61 -> {
                            topMidArchArea++
                            if (fg) topMidArchCnt++
                        }
                        xRel in 0.62..0.86 -> {
                            topRightArchArea++
                            if (fg) topRightArchCnt++
                        }
                    }
                }
                if (yRel in 0.56..0.74 && xRel in 0.34..0.66) {
                    botRingArea++
                    if (fg) botRingCnt++
                }
                if (yRel in 0.32..0.58 && xRel in 0.36..0.64) {
                    coreArea++
                    if (fg) coreCnt++
                }

                if (!fg) continue
                normXs[idx] = xRel
                normYs[idx] = yRel
                idx++

                if (yRel < 0.12) {
                    topPeakSumX += xRel
                    topPeakCnt++
                }
                when {
                    yRel < 0.34 -> {
                        topSumX += xRel
                        topCnt++
                    }
                    yRel < 0.64 -> {
                        midSumX += xRel
                        midCnt++
                    }
                    yRel < 0.78 -> {
                        lowShaftSumX += xRel
                        lowShaftCnt++
                    }
                    else -> {
                        botSumX += xRel
                        botCnt++
                        if (xRel < 0.44) botLeftMass++ else if (xRel > 0.56) botRightMass++
                    }
                }

                if (yRel in 0.28..0.60) {
                    if (xRel < 0.36) uLeftMidCols++
                    if (xRel > 0.64) uRightMidCols++
                }
                if (yRel in 0.58..0.88) {
                    if (xRel < 0.42) lowLeftCnt++
                    if (xRel > 0.58) lowRightCnt++
                }

                val dxRing = xRel - 0.50
                val dyRing = yRel - 0.44
                val distSq = dxRing * dxRing + dyRing * dyRing
                if (distSq in (0.14 * 0.14)..(0.42 * 0.42)) {
                    val angle = atan2(dyRing, dxRing) + Math.PI
                    val sector = ((angle / (2.0 * Math.PI)) * 8.0).toInt().coerceIn(0, 7)
                    sectorsHit[sector]++
                }
            }
        }

        if (topCnt == 0 || midCnt == 0 || botCnt == 0) return -1
        val xTop = topSumX / topCnt
        val xTopPeak = if (topPeakCnt > 0) topPeakSumX / topPeakCnt else xTop
        val xMid = midSumX / midCnt
        val xLowShaft = if (lowShaftCnt > 0) lowShaftSumX / lowShaftCnt else xMid
        val xBot = botSumX / botCnt

        val topLeftFill = topLeftArchCnt.toDouble() / topLeftArchArea.coerceAtLeast(1)
        val topMidFill = topMidArchCnt.toDouble() / topMidArchArea.coerceAtLeast(1)
        val topRightFill = topRightArchCnt.toDouble() / topRightArchArea.coerceAtLeast(1)
        val botRingFill = botRingCnt.toDouble() / botRingArea.coerceAtLeast(1)
        val coreFill = coreCnt.toDouble() / coreArea.coerceAtLeast(1)

        var ringSectorsPopulated = 0
        for (s in sectorsHit) {
            if (s >= 2) ringSectorsPopulated++
        }

        // 1. Roundabout (8): closed circular loop with hollow center
        if (coreArea >= 8 &&
            coreFill < 0.24 &&
            ringSectorsPopulated >= 6 &&
            botRingFill > 0.25 &&
            topMidFill > 0.22
        ) {
            return 8
        }

        // 2. U-turn (4): true U arch spans left + center + right at top, splits immediately below
        //    into 2 parallel vertical runs, and descends back on the opposite side of the stem.
        val hasFullTopArch = topLeftFill > 0.22 && topMidFill > 0.25 && topRightFill > 0.22
        val oneSidedStem = abs(xBot - 0.50) >= 0.12 || abs(botLeftMass - botRightMass) >= 3
        val oppositeReturnTipPresent = if (xBot >= 0.50) lowLeftCnt >= 4 else lowRightCnt >= 4
        if (hasFullTopArch &&
            upperTwoRunRows >= 3 &&
            uLeftMidCols >= 6 &&
            uRightMidCols >= 6 &&
            oppositeReturnTipPresent &&
            botRingFill < 0.48 &&
            oneSidedStem
        ) {
            return 4
        }

        // 3. Wing & tip geometry relative to trunk center xBot
        var leftWingCnt = 0
        var rightWingCnt = 0
        var leftFarCnt = 0
        var leftFarSumY = 0.0
        var leftFarMaxY = 0.0
        var rightFarCnt = 0
        var rightFarSumY = 0.0
        var rightFarMaxY = 0.0
        var topLeftCnt = 0
        var topRightCnt = 0

        for (i in 0 until idx) {
            val xRel = normXs[i]
            val yRel = normYs[i]
            if (xRel < xBot - 0.14) leftWingCnt++
            if (xRel > xBot + 0.14) rightWingCnt++
            if (yRel < 0.45) {
                if (xRel < 0.45) topLeftCnt++ else if (xRel > 0.55) topRightCnt++
            }
            if (xRel < 0.26) {
                leftFarCnt++
                leftFarSumY += yRel
                if (yRel > leftFarMaxY) leftFarMaxY = yRel
            }
            if (xRel > 0.74) {
                rightFarCnt++
                rightFarSumY += yRel
                if (yRel > rightFarMaxY) rightFarMaxY = yRel
            }
        }

        val dxTop = xTop - xBot
        val dxMid = xMid - xBot
        val wingAsym = (rightWingCnt - leftWingCnt).toDouble() / fgCount.toDouble()

        // 4. Straight (0): centered trunk and centered top with near-symmetric wings
        if (xBot in 0.36..0.64 &&
            abs(dxTop) < 0.10 &&
            abs(dxMid) < 0.10 &&
            abs(wingAsym) < 0.12
        ) {
            return 0
        }

        // 5. Right-side maneuvers (slight 1, 90° right 2, sharp right 3)
        val leansRight = dxTop >= 0.09 || dxMid >= 0.14 || wingAsym >= 0.10
        val leansLeft = dxTop <= -0.09 || dxMid <= -0.14 || wingAsym <= -0.10

        if (leansRight && !leansLeft) {
            val rightFarMeanY = if (rightFarCnt > 0) rightFarSumY / rightFarCnt else 0.35
            if (xBot <= 0.48 && rightFarCnt >= 5 && rightFarMeanY >= 0.44 && rightFarMaxY >= 0.58) {
                return 3 // Sharp right (hooks down-right)
            }
            val shaftLeansGradually = abs(xLowShaft - xBot) >= 0.09
            val isSlightRight = xTopPeak >= 0.70 &&
                rightFarMeanY <= 0.24 &&
                (shaftLeansGradually || topLeftFill < 0.10)
            if (isSlightRight) {
                return 1 // Slight right
            }
            if (dxTop >= 0.20 || dxMid >= 0.19 || (xBot <= 0.46 && rightFarCnt >= 5 && topRightCnt >= 4)) {
                return 2 // Turn right
            }
            return 1
        }

        // 6. Left-side maneuvers (slight 7, 90° left 6, sharp left 5)
        if (leansLeft && !leansRight) {
            val leftFarMeanY = if (leftFarCnt > 0) leftFarSumY / leftFarCnt else 0.35
            if (xBot >= 0.52 && leftFarCnt >= 5 && leftFarMeanY >= 0.44 && leftFarMaxY >= 0.58) {
                return 5 // Sharp left (hooks down-left)
            }
            val shaftLeansGradually = abs(xLowShaft - xBot) >= 0.09
            val isSlightLeft = xTopPeak <= 0.30 &&
                leftFarMeanY <= 0.24 &&
                (shaftLeansGradually || topRightFill < 0.10)
            if (isSlightLeft) {
                return 7 // Slight left
            }
            if (dxTop <= -0.20 || dxMid <= -0.19 || (xBot >= 0.54 && leftFarCnt >= 5 && topLeftCnt >= 4)) {
                return 6 // Turn left
            }
            return 7
        }

        val combinedSigned = dxTop * 1.4 + dxMid + wingAsym
        return when {
            combinedSigned >= 0.18 -> 2
            combinedSigned >= 0.07 -> 1
            combinedSigned <= -0.18 -> 6
            combinedSigned <= -0.07 -> 7
            else -> 0
        }
    }
}
