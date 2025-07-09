import Toybox.Activity;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;
import Toybox.FitContributor;
import Toybox.Graphics;
import Toybox.Application;

class GradeEstimatorView extends WatchUi.DataField {
    // CONFIG
    const SAMPLE_WINDOW         = 30;       // buffer size (longer buffer)
    const MIN_GRADE_WINDOW      = 5;        // minimum samples for grade calc
    const MAX_GRADE_WINDOW     = 20;       // maximum samples for grade calc
    const SAMPLE_MISS_THRESHOLD = 2;     // how many samples can be missed
    const THRESHOLD_LIGHT    = 0.05;     // percent
    const THRESHOLD_STEEP    = 0.10;    // percent
    const FIELD_ID_GRADE     = 30;      // grade, REC
    const FIELD_ID_LIGHT     = 31;      // meters ≥ 5%, SESSION
    const FIELD_ID_STEEP     = 32;      // meters ≥10%, SESSION
    const FIELD_ID_MAXGRADE  = 33;      // max grade,   SESSION
    const FIELD_ID_VAM_GRAPH = 34;      // grade, REC
    const FIELD_ID_VAM_AVG   = 35;      // grade, REC
    const MAX_ALT_JUMP       = 10;
    const DIST_LOG_QUALITY   = 0.25;    // Quality threshold for distance calculation
    const MAX_LOG_QUALITY    = 0.5;     // Quality threshold for maximum grade

    const buffer_str        = "|";
    const blank_str         = "-.-";
    const suffix            = "%";
    const str_format        = "%+.1f";
    const vam_str_format    = "%d";

    var str_buffering as String = "";
    var str_active as String = "";
    var str_no_data as String = "";

    // STATE
    var buffer as Array<Dictionary> = [];
    var rawAltitudes as Array<Float> = [];
    var prevMedianAlt as Float or Null = null; // Previous median altitude for jump detection
    var bufIndex as Number     = 0;
    var accWinDist as Float    = 0.0;  // over window
    var grade as Float         = 0.0;  // fraction, e.g. 0.05 = 5%
    var distLight as Float     = 0.0;  // meters at ≥5%
    var distSteep as Float     = 0.0;  // meters at ≥10%
    var maxGrade as Float      = 0.0;  // maximum grade encountered
    var lastSample as Number   = 0;
    var vam as Float           = 0.0;  // VAM in m/h
    var vamAvg as Float        = 0.0;  // Average VAM in m/h
    var numValid               = 0;

    var sumAscentVam as Float   = 0.0; // Sum of ascenting VAM (+5%)
    var samplesAscent as Number = 0; // Number of samples with ascenting VAM

    // Adaptive window state
    var gradeWindowSize as Number = 10; // Start at 10, will be clamped between 6 and 20

    // FIT FIELDS
    var vamField, vamAvgField, gradeField, lightField, steepField, maxField;

    // UI
    var textColor as Number      = Graphics.COLOR_WHITE;
    var drawCompact as Boolean   = false; // Compact view for small screens
    var drawGraph as Boolean     = false; // Draw altitude buffer graph

    // STATUS STATE
    var calculating as Boolean  = false;
    var quality as Float        = 0.0;

    function getProgressBar(progress as Float, length as Number) as String {
        var bar = "";
        var numBlocks = Math.floor(progress * length);
        for (var i = 0; i < length; i++) {
            if (i < numBlocks) {
                bar += "█"; // filled block
            } else {
                bar += "░"; // empty block
            }
        }
        return bar;
    }

    function getRotatingIcon() as String {
        // Returns a back-and-forth moving solid square in a n-char bar
        var barLength = 5;
        var t = (Time.now().value()) % ((barLength - 1) * 2);
        var pos;
        if (t < barLength - 1) {
            pos = t;
        } else {
            pos = (barLength - 1) * 2 - t;
        }
        var icon = "";
        for (var i = 0; i < barLength; i++) {
            if (i == pos) {
                icon += "█";
            } else {
                icon += "░";
            }
        }
        return icon;
    }

    // Helper: median of three values
    function median3(a, b, c) {
        if ((a <= b && b <= c) || (c <= b && b <= a)) { return b; }
        if ((b <= a && a <= c) || (c <= a && a <= b)) { return a; }
        return c;
    }

    function getStatusString() as String {
        var c = "";
        var barlength = drawCompact ? 10 : 13;
        if (calculating) {
            c = str_active + " ";
            var progress = Math.sqrt((gradeWindowSize.toFloat() - MIN_GRADE_WINDOW + 1) / (MAX_GRADE_WINDOW - MIN_GRADE_WINDOW + 1));
            c += getProgressBar(progress, barlength);
            c += " |" + gradeWindowSize.format("%d") + "s";
            if (!drawCompact) { c += "|" + numValid.format("%d") + "s";}
        } else if (bufIndex > 0) {
            c = str_buffering + " ";
            c += getProgressBar(bufIndex.toFloat() / MIN_GRADE_WINDOW, 19 - str_buffering.length());
        }
        else {
            c = str_no_data + " ";
            c += getRotatingIcon();
        }
        return c;
    }

    function isWatchDevice() {
        var layout = System.getDeviceSettings().screenShape;

        return (layout == System.SCREEN_SHAPE_ROUND);
    }

    function initialize() {
        DataField.initialize();

        // Initialize strings
        str_buffering = WatchUi.loadResource(Rez.Strings.UI_Label_Status_Buffering);
        str_active = WatchUi.loadResource(Rez.Strings.UI_Label_Status_Active);
        str_no_data = WatchUi.loadResource(Rez.Strings.UI_Label_Status_NoData);

        // Graphs
        gradeField = createField(
            WatchUi.loadResource(Rez.Strings.GC_ChartTitle_Grade), FIELD_ID_GRADE,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_RECORD, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade) }
        );
        gradeField.setData(0.0);

        vamField = createField(
            WatchUi.loadResource(Rez.Strings.GC_ChartTitle_VAM), FIELD_ID_VAM_GRAPH,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_RECORD, :units=>WatchUi.loadResource(Rez.Strings.Unit_VAM) }
        );
        vamField.setData(0.0);

        // Session totals
        lightField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_Distance_Light), FIELD_ID_LIGHT,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_Distance)}
        );
        lightField.setData(0.0);

        steepField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_Distance_Steep), FIELD_ID_STEEP,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_Distance)}
        );
        steepField.setData(0.0);

        maxField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_Grade_Max), FIELD_ID_MAXGRADE,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade)}
        );
        maxField.setData(0.0);

        vamAvgField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_AverageVAM), FIELD_ID_VAM_AVG,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_VAM)}
        );
        vamAvgField.setData(0.0);

        // Initialize rolling buffer
        buffer = [];
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            buffer.add({ "altitude" => 0.0, "distance" => 0.0 });
        }
        rawAltitudes = [];
        _resetAll(true);
        grade      = 0.0;
        distLight  = 0.0;
        distSteep  = 0.0;
    }

    function onLayout(dc as Dc) as Void  {
        var width_view = dc.getWidth();
        var height_view = dc.getHeight();
        var width_device = System.getDeviceSettings().screenWidth;
        var height_device = System.getDeviceSettings().screenHeight;

        if (width_view < width_device / 2 + 10) {
            View.setLayout(Rez.Layouts.SmallLayout(dc));
            drawCompact = true; // Compact labels for small views
            drawGraph = false; // No graph in compact view
        }
        else {
            drawCompact = false; // Full length labels for wide views

            if (height_view < (height_device / 3) - 3) { 
                View.setLayout(Rez.Layouts.WideLayout(dc));
                drawGraph = false; // No graph in wide view
            }
            else { 
                View.setLayout(Rez.Layouts.LargeLayout(dc));
                drawGraph = true; // Draw altitude buffer graph in wide view
            }
        }
    }

    function compute(info) {
        // Assume exactly 1 Hz
        var speed    = (info has :currentSpeed) ? info.currentSpeed : null;
        var altitude = (info has :altitude) ? info.altitude : null;
        var eTime = (info has :elapsedTime) ? info.elapsedTime / 1000 : 0;

        if (speed == null || altitude == null) { return blank_str; }

        System.println(eTime + "," + info.elapsedDistance + ","  + speed + "," + altitude + "," + gradeWindowSize + "," + grade);

        var sample_distance = speed * 1; // expect one second sample interval

        // Reset if nearly stopped or if more than x samples missed (missing 1 sample should be rare)
        if (speed < 1.0 || eTime > lastSample + SAMPLE_MISS_THRESHOLD) {
            _resetAll(false);
            gradeField.setData(0.0);
            lastSample = eTime;
            return blank_str;
        }
        else if (eTime > lastSample + 1.1) { // We missed one sample
            var dt = eTime - lastSample;
            sample_distance = speed * dt; // Adjust distance based on elapsed time
        }

        lastSample = eTime;

        // Median filter for altitude using only real raw values
        rawAltitudes.add(altitude);
        if (rawAltitudes.size() > 3) { rawAltitudes = rawAltitudes.slice(1, rawAltitudes.size()); }
        var medianAlt;
        if (rawAltitudes.size() == 3) {
            medianAlt = median3(rawAltitudes[0], rawAltitudes[1], rawAltitudes[2]);
        } else {
            medianAlt = altitude;
        }

        if (prevMedianAlt != null && (medianAlt - prevMedianAlt).abs() > MAX_ALT_JUMP) {
            // If the altitude jumped too much, reset the buffer
            _resetAll(true);
            gradeField.setData(0.0);
            lastSample = eTime;
            return blank_str;
        }

        // Update rolling window
        buffer[bufIndex] = { "altitude" => medianAlt, "distance" => sample_distance };   // Replace oldest sample
        accWinDist += sample_distance;                                                  // Accumulate distance with current movement
        bufIndex = (bufIndex + 1) % SAMPLE_WINDOW;                              // Iterate rolling buffer index
        accWinDist -= buffer[bufIndex]["distance"];

        // Track how many valid samples are in the buffer
        numValid = 0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            if (buffer[i]["altitude"] != 0.0) { numValid++; }
        }

        if (accWinDist < 5 || numValid < MIN_GRADE_WINDOW) {
            gradeField.setData(0.0);
            return blank_str;
        }

        // --- Adaptive window selection (new logic) ---
        // Clamp window size between 6 and 20, and not more than numValid
        if (gradeWindowSize < MIN_GRADE_WINDOW) { gradeWindowSize = MIN_GRADE_WINDOW; }
        if (gradeWindowSize > MAX_GRADE_WINDOW) { gradeWindowSize = MAX_GRADE_WINDOW; }
        if (gradeWindowSize > numValid) { gradeWindowSize = numValid; }

        // Compute main grade with current window size
        var mainGrade = computeWindowSlope(buffer, bufIndex, gradeWindowSize, SAMPLE_WINDOW);
        // Compute min grade with window size 6 (if enough samples)
        var minGrade = computeWindowSlope(buffer, bufIndex, MIN_GRADE_WINDOW, SAMPLE_WINDOW);
        
        // Compare and adjust window size for next call
        var gradeDiff = (mainGrade - minGrade).abs();
        if (gradeDiff > 0.03)       { gradeWindowSize -= 4; }
        else if (gradeDiff > 0.02)  { gradeWindowSize -= 3; }
        else if (gradeDiff > 0.015) { gradeWindowSize -= 2; }
        else if (gradeDiff > 0.01)  { gradeWindowSize -= 1; } 
        else if (gradeDiff < 0.004 && gradeWindowSize <= MAX_GRADE_WINDOW / 2) 
                                    { gradeWindowSize += 1; }
        else if (gradeDiff < 0.002) { gradeWindowSize += 1; }

        // Clamp window size between 6 and 20, and not more than numValid
        if (gradeWindowSize < MIN_GRADE_WINDOW) { gradeWindowSize = MIN_GRADE_WINDOW; }
        if (gradeWindowSize > MAX_GRADE_WINDOW) { gradeWindowSize = MAX_GRADE_WINDOW; }
        if (gradeWindowSize > numValid) { gradeWindowSize = numValid; }

        // Use the main grade window for regression and display
        computeLinearRegressionSlope(buffer, bufIndex, gradeWindowSize);

        // Accumulate distance in each zone
        if (grade >= THRESHOLD_LIGHT && quality > DIST_LOG_QUALITY) { distLight += sample_distance; }
        if (grade >= THRESHOLD_STEEP && quality > DIST_LOG_QUALITY) { distSteep += sample_distance; }
        if (grade > maxGrade && quality > MAX_LOG_QUALITY) { maxGrade = grade; }

        // Export
        gradeField.setData(grade * 100);

        // Update session summary fields
        lightField.setData(distLight / 1000.0);
        steepField.setData(distSteep / 1000.0);
        maxField.setData(maxGrade * 100); 

        computeVAM(grade, speed);

        prevMedianAlt = medianAlt;

        return blank_str;
    }

    function computeLinearRegressionSlope(samples as Array<Dictionary>, bufIndex as Number, windowSize as Number) {
        var xVals = [];
        var dist = 0.0;
        calculating = true;

        // Use only the last windowSize samples
        for (var i = 0; i < windowSize; i++) {
            var idx = (bufIndex + SAMPLE_WINDOW - windowSize + i) % SAMPLE_WINDOW;
            dist += samples[idx]["distance"];
            xVals.add(dist);
        }

        var sumX = 0.0, sumY = 0.0;
        for (var i = 0; i < windowSize; i++) {
            var idx = (bufIndex + SAMPLE_WINDOW - windowSize + i) % SAMPLE_WINDOW;
            sumY += samples[idx]["altitude"];
            sumX += xVals[i];
        }
        var meanX = sumX / windowSize;
        var meanY = sumY / windowSize;

        var covXY = 0.0, varX = 0.0;
        for (var i = 0; i < windowSize; i++) {
            var idx = (bufIndex + SAMPLE_WINDOW - windowSize + i) % SAMPLE_WINDOW;
            var dx = xVals[i] - meanX;
            var dy = samples[idx]["altitude"] - meanY;
            covXY += dx * dy;
            varX += dx * dx;
        }
        
        grade = (varX > 0.0) ? (covXY / varX) : 0.0;
        var sse = 0.0;
        for (var i = 0; i < windowSize; i++) {
            var idx = (bufIndex + SAMPLE_WINDOW - windowSize + i) % SAMPLE_WINDOW;
            var measAltDelta = samples[idx]["altitude"] - meanY;
            var AltDelta = grade * (xVals[i] - meanX);
            var res = (AltDelta - measAltDelta);

            sse += res*res;
        }

        if (varX > 0.0) {
            var sem = Math.sqrt((sse / (windowSize - 2)) / varX);
            quality = 0.005 / (0.005 + sem); // Quality measure based on standard error of the slope
        }
        else {
            quality = -1.0; // No valid data
            calculating = false; // We don't really have any data. This should never happen.
        }
    }

    // Helper: compute slope for a window of the buffer
    function computeWindowSlope(samples as Array<Dictionary>, bufIndex as Number, windowSize as Number, bufferLen as Number) as Float {
        var xVals = [];
        var dist = 0.0;
        for (var i = 0; i < windowSize; i++) {
            var idx = (bufIndex + bufferLen - windowSize + i) % bufferLen;
            dist += samples[idx]["distance"];
            xVals.add(dist);
        }
        var sumX = 0.0, sumY = 0.0;
        for (var i = 0; i < windowSize; i++) {
            var idx = (bufIndex + bufferLen - windowSize + i) % bufferLen;
            sumY += samples[idx]["altitude"];
            sumX += xVals[i];
        }
        var meanX = sumX / windowSize;
        var meanY = sumY / windowSize;
        var covXY = 0.0, varX = 0.0;
        for (var i = 0; i < windowSize; i++) {
            var idx = (bufIndex + bufferLen - windowSize + i) % bufferLen;
            var dx = xVals[i] - meanX;
            var dy = samples[idx]["altitude"] - meanY;
            covXY += dx * dy;
            varX += dx * dx;
        }
        return (varX > 0.0) ? (covXY / varX) : 0.0;
    }

    function computeVAM(grade as Float, speed as Float) as Float {
        // Compute VAM based on grade and speed
        if (grade > 0.0 && speed > 0.0) {
            vam = speed * grade * 3600; // in m/h
        }
        else { vam = 0.0; }

        if (grade > THRESHOLD_LIGHT && quality > DIST_LOG_QUALITY) {
            // Accumulate VAM for ascenting segments
            sumAscentVam += vam;
            samplesAscent++;

            vamAvg = sumAscentVam / samplesAscent;
        }

        vamField.setData(vam);
        vamAvgField.setData(vamAvg);

        return vam;
    }

    function onUpdate(dc as Dc) as Void {
        

        var background = View.findDrawableById("Background") as Text;
        background.setColor(getBackgroundColor());

        textColor = Graphics.COLOR_WHITE;
        if (getBackgroundColor() == Graphics.COLOR_WHITE) { textColor = Graphics.COLOR_BLACK;}

        setLabelColor(dc);

        drawDefaultView(dc);
        drawVAMFields(dc);
        drawStatusLabel(dc);

        View.onUpdate(dc);
        
        if (drawGraph) { drawAltitudeBufferPlot(dc); }
    }

    function drawDefaultView(dc as Dc) as Void {
        var value_curr_grade = View.findDrawableById("value_curr_grade") as Text;
        var value_max_grade = View.findDrawableById("value_max_grade") as Text;
        var value_light = View.findDrawableById("value_light") as Text;
        var value_steep = View.findDrawableById("value_steep") as Text;
        
        if (value_curr_grade != null)
        {
            if (calculating) { value_curr_grade.setColor(textColor); }
            else { value_curr_grade.setColor(Graphics.COLOR_LT_GRAY); } // Set gray color if not active

            value_curr_grade.setText((100 * grade).format(str_format) + suffix);
        }

        if (value_max_grade != null)
        {
            value_max_grade.setColor(textColor);
            value_max_grade.setText((100*maxGrade).format(str_format) + suffix);
        }

        if (value_light != null)
        {
            value_light.setColor(textColor);
            value_light.setText((distLight/1000).format("%.1f") + " km");
        }

        if (value_steep != null)
        {
            value_steep.setColor(textColor);
            value_steep.setText((distSteep/1000).format("%.1f") + " km");
        }
    }

    function drawVAMFields(dc as Dc) as Void {
        var value_vam = View.findDrawableById("value_vam") as Text;
        var value_vam_avg = View.findDrawableById("value_vam_avg") as Text;

        if (value_vam != null) {
            if (vam > 0) { value_vam.setColor(textColor); }
            else { value_vam.setColor(Graphics.COLOR_LT_GRAY); } // Set gray color if no VAM

            value_vam.setText((vam).format(vam_str_format) + (drawCompact ? "" : " m/h"));
        }

        if (value_vam_avg != null) {
            value_vam_avg.setColor(textColor);
            value_vam_avg.setText((vamAvg).format(vam_str_format) + (drawCompact ? "" : " m/h"));
        }
    }

    function setLabelColor(dc as Dc) as Void {
        var labels = ["label_curr_grade", "label_max_grade", "label_light", "label_steep", "label_vam", "label_vam_avg"];
        for (var i = 0; i < labels.size(); i++) {
            var label = labels[i];

            // Find the labels by ID and set its color
            var labelDrawable = View.findDrawableById(label) as Text;
            if (labelDrawable != null) {
                labelDrawable.setColor(textColor);
            }
        }
    }

    function drawStatusLabel(dc as Dc) as Void {
        var statusLabel = View.findDrawableById("label_status") as Text;
        if (statusLabel != null) {
            statusLabel.setColor(textColor);
            statusLabel.setText(getStatusString());
        }
    }

    function drawAltitudeBufferPlot(dc as Dc) as Void {
        // --- Plot area setup ---
        var width = dc.getWidth();
        var height = dc.getHeight();
        var margin = 10;
        var plotLeft = margin;
        var plotRight = width - margin;
        var plotTop = height / 2;
        var plotHeight = height - plotTop - margin;
        var plotBottom = plotTop + plotHeight;
        var plotWidth = plotRight - plotLeft;

        // --- Recalculate valid buffer (oldest to newest) ---
        var sampleCount = numValid;
        if (sampleCount > 1) {
            var validDistances = new [sampleCount];
            var validAltitudes = new [sampleCount];
            var accDist = 0.0;
            for (var i = 0; i < sampleCount; i++) {
                var idx = (bufIndex + i) % sampleCount;

                validDistances[i] = accDist;
                validAltitudes[i] = buffer[idx]["altitude"];

                accDist += buffer[idx]["distance"];
            }

            // --- X/Y range with 1m margin ---
            var minX = validDistances[0] - 1.0;
            var maxX = validDistances[sampleCount - 1] + 1.0;
            var minY = validAltitudes[0];
            var maxY = validAltitudes[0];
            for (var i = 0; i < sampleCount; i++) {
                if (validAltitudes[i] < minY) { minY = validAltitudes[i]; }
                if (validAltitudes[i] > maxY) { maxY = validAltitudes[i]; }
            }
            minY -= 1.0; // Add margin to Y
            maxY += 1.0; // Add margin to Y
            var xrange = maxX - minX;
            var yrange = maxY - minY;

            if (xrange < 50.0) {
                minX = maxX - 50.0; // Ensure we have a reasonable minimum range
                xrange = 50.0;
            }

            // --- Draw buffer as polyline ---
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            for (var j = 0; j < sampleCount - 1; j++) {
                var x1 = plotLeft + ((validDistances[j] - minX) / xrange) * plotWidth;
                var x2 = plotLeft + ((validDistances[j+1] - minX) / xrange) * plotWidth;
                var y1 = plotBottom - ((validAltitudes[j] - minY) / yrange) * plotHeight;
                var y2 = plotBottom - ((validAltitudes[j+1] - minY) / yrange) * plotHeight;
                dc.drawLine(x1, y1, x2, y2);
            }

            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(plotLeft + plotWidth / 2, plotBottom - 15, Graphics.FONT_SYSTEM_XTINY, "← " + xrange.format("%.1f") + "m →", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(plotLeft + 3, plotTop + 3, Graphics.FONT_SYSTEM_XTINY, "↕ " + yrange.format("%.1f") + "m", Graphics.TEXT_JUSTIFY_LEFT);

            if (calculating) {
                // --- Draw regression line through the mean point with correct slope ---
                var windowStartIdx = sampleCount - gradeWindowSize;
                if (windowStartIdx < 0) { windowStartIdx = 0; }
                var slope = grade;

                // Compute mean X and mean Y for the regression window
                var sumX = 0.0, sumY = 0.0;
                var n = 0;
                for (var i = sampleCount - 1; i >= windowStartIdx; i--) {
                    sumX += validDistances[i];
                    sumY += validAltitudes[i];
                    n++;
                }
                var meanX = sumX / n;
                var meanY = sumY / n;

                // Compute regression line endpoints for the window
                var xStart = validDistances[windowStartIdx];
                var xEnd = validDistances[sampleCount - 1];
                var yStart = meanY + slope * (xStart - meanX);
                var yEnd = meanY + slope * (xEnd - meanX);

                var px1 = plotLeft + ((xStart - minX) / xrange) * plotWidth;
                var px2 = plotLeft + ((xEnd - minX) / xrange) * plotWidth;
                var py1 = plotBottom - ((yStart - minY) / yrange) * plotHeight;
                var py2 = plotBottom - ((yEnd - minY) / yrange) * plotHeight;

                dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
                dc.setPenWidth(2);
                dc.drawLine(px1, py1, px2, py2);

                dc.drawText(plotLeft + plotWidth - 7, plotBottom - 15, Graphics.FONT_SYSTEM_XTINY, "← " + (xEnd - xStart).format("%.1f") + "m", Graphics.TEXT_JUSTIFY_RIGHT);
            }
        }

        // --- Draw plot area border ---
        dc.setColor(textColor, Graphics.COLOR_BLACK);
        dc.setPenWidth(2);
        dc.drawRectangle(plotLeft, plotTop, plotWidth, plotHeight);
    }

    hidden function _resetAll(deleteAll as Boolean) as Void {
        accWinDist   = 0.0;
        bufIndex = 0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            buffer[i] = { "altitude" => 0.0, "distance" => 0.0 }; 
        }
        rawAltitudes = [];
        calculating = false;
        gradeWindowSize = MIN_GRADE_WINDOW; // Reset adaptive window size
        prevMedianAlt = null; // Reset previous median altitude
    }
}