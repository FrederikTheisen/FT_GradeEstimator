import Toybox.Activity;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;
import Toybox.FitContributor;
import Toybox.Graphics;
import Toybox.Application;


class GradeEstimatorView extends WatchUi.DataField {
    // CONFIG
    const SAMPLE_WINDOW      = 11;       // seconds
    const EMA_ALPHA          = 0.25;    // smoothing factor
    const EMA_ALT_ALPHA      = 0.5;    // altitude effect
    const THRESHOLD_LIGHT    = 5.0;     // percent
    const THRESHOLD_STEEP    = 10.0;    // percent
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

    // STATE
    var buffer as Array<Dictionary> = [];
    var rawAltitudes as Array<Float> = [];
    var bufIndex as Number     = 0;
    var accWinDist as Float    = 0.0;  // over window
    var dh as Float            = 0.0;  // delta altitude
    var grade as Float         = 0.0;  // fraction, e.g. 0.05 = 5%
    var distLight as Float     = 0.0;  // meters at ≥5%
    var distSteep as Float     = 0.0;  // meters at ≥10%
    var maxGrade as Float      = 0.0;  // maximum grade encountered
    var bufFull as Boolean     = false;
    var lastSample as Number   = 0;
    var vam as Float           = 0.0;  // VAM in m/h
    var vamAvg as Float        = 0.0;  // Average VAM in m/h

    var sumAscentVam as Float   = 0.0; // Sum of ascenting VAM (+5%)
    var samplesAscent as Number = 0; // Number of samples with ascenting VAM

    var kf as AltitudeGradientKalman or Null;
    var kf_grade               = 0.0;

    // FIT FIELDS
    var vamField, vamAvgField, gradeField, lightField, steepField, maxField;

    // UI
    var shouldDrawVam as Boolean = false;
    var textColor as Number      = Graphics.COLOR_WHITE;
    var drawCompact as Boolean   = false; // Compact view for small screens
    var drawGraph as Boolean     = false; // Draw altitude buffer graph

    // STATUS STATE
    var calculating as Boolean  = false;
    var quality as Float        = 0.0;

    function getBufferString() as String {
        var str = "";
        for (var i = 0; i < SAMPLE_WINDOW; i += 1) {
            if (i < bufIndex) { str += "|"; }
            else { str += "."; }
        }
        str += "";

        return str;
    }

    function getPausedString() as String {
        return "|||" + (100*grade).format(str_format) + suffix + "|||";
    }

    function getProgressBar(progress as Float) as String {
        var bar = "";
        var numBlocks = Math.floor(progress * 10);
        for (var i = 0; i < 10; i++) {
            if (i < numBlocks) {
                bar += "█"; // filled block
            } else {
                bar += "░"; // empty block
            }
        }
        return bar;
    }

    // Helper: median of three values
    function median3(a, b, c) {
        if ((a <= b && b <= c) || (c <= b && b <= a)) { return b; }
        if ((b <= a && a <= c) || (c <= a && a <= b)) { return a; }
        return c;
    }

    function getStatusString() as String {
        var c = "";
        if (calculating) {
            c = "ACTIVE ";
            c += getProgressBar(quality);
            //c += " e/d: " + dh.format("%.1f") + "m/" + accWinDist.format("%.1f") + "m";
        } else if (bufIndex > 0) {
            c = "BUFFERING ";
            c += getProgressBar(bufIndex.toFloat() / SAMPLE_WINDOW);
        }
        else {
            c = "NO DATA";
        }
        return c;
    }

    function initialize() {
        DataField.initialize();

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
        _resetAll();
        grade      = 0.0;
        distLight  = 0.0;
        distSteep  = 0.0;
    }

    function drawAltitudeBufferPlot(dc as Dc) as Void {
        // Plot area
        var width = dc.getWidth();
        var height = dc.getHeight();
        var margin = 10;
        var plotTop = height / 2;
        var plotHeight = height - plotTop - margin;
        var plotBottom = plotTop + plotHeight;
        var plotLeft = margin;
        var plotRight = width - margin;
        var plotWidth = plotRight - plotLeft;

        // Compute cumulative X values (distance)
        var xVals = [];
        var totalDist = 0.0;
        var n = 0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            xVals.add(totalDist);
            totalDist += buffer[i]["distance"];

            if (buffer[i]["altitude"] != 0.0) { n++; }
        }
        if (n == 0) { n = 1; } // Avoid division by zero
        var minX = 0.0;
        var maxX = totalDist > 0 ? totalDist : 1.0;

        // Compute meanX, meanY, slope, intercept as before
        var sumX = 0.0, sumY = 0.0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            sumY += buffer[i]["altitude"];
            sumX += xVals[i];
        }
        var meanX = sumX / n;
        var meanY = sumY / n;

        // Find min/max altitude in buffer for scaling
        // var minAlt = 1e9;
        // var maxAlt = -1e9;
        // for (var i = 0; i < SAMPLE_WINDOW; i++) {
        //     var alt = buffer[i]["altitude"];
        //     if (alt < minAlt) { minAlt = alt; }
        //     if (alt > maxAlt) { maxAlt = alt; }
        // }

        var maxDeltaH = totalDist * 0.15; // max 25% slope
        var maxAlt = meanY + maxDeltaH / 2 + 1;
        var minAlt = meanY - maxDeltaH / 2 - 1;

        // Draw buffer as polyline using scaled X
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_GREEN);
        dc.setPenWidth(2);
        var xrange = maxX - minX;
        var altrange = maxAlt - minAlt;
        for (var i = 0; i < n - 1; i++) {
            var idx = (bufIndex + i) % SAMPLE_WINDOW;
            var idx_p1 = (bufIndex + i + 1) % SAMPLE_WINDOW;
            var x1 = plotLeft + ((xVals[i] - minX) / xrange) * plotWidth;
            var x2 = plotLeft + ((xVals[i+1] - minX) / xrange) * plotWidth;
            var y1 = plotBottom - ((buffer[idx]["altitude"] - minAlt) / altrange) * plotHeight;
            var y2 = plotBottom - ((buffer[idx_p1]["altitude"] - minAlt) / altrange) * plotHeight;

            if (x1 < plotLeft) { x1 = plotLeft; }
            if (x2 > plotRight) { x2 = plotRight; }
            if (y1 > plotBottom) { y1 = plotBottom; }
            else if (y1 < plotTop) { y1 = plotTop; }
            if (y2 > plotBottom) { y2 = plotBottom; }
            else if (y2 < plotTop) { y2 = plotTop; }

            dc.drawLine(x1, y1, x2, y2);
        }

        // Draw linear fit
        var slope = grade;
        var intercept = meanY - slope * meanX;
        // Draw fit line
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_YELLOW);
        dc.setPenWidth(1);
        for (var i = 0; i < SAMPLE_WINDOW - 1; i++) {
            var x1 = plotLeft + ((xVals[i] - minX) / (maxX - minX)) * plotWidth;
            var x2 = plotLeft + ((xVals[i+1] - minX) / (maxX - minX)) * plotWidth;
            var fitY1 = intercept + slope * xVals[i];
            var fitY2 = intercept + slope * xVals[i+1];
            var y1 = plotBottom - ((fitY1 - minAlt) / (maxAlt - minAlt)) * plotHeight;
            var y2 = plotBottom - ((fitY2 - minAlt) / (maxAlt - minAlt)) * plotHeight;
            dc.drawLine(x1, y1, x2, y2);
        }

        // Draw plot area
        dc.setColor(textColor, Graphics.COLOR_BLACK);
        dc.setPenWidth(3);
        dc.drawRectangle(plotLeft, plotTop, plotWidth, plotHeight);
    }

    function onLayout(dc as Dc) as Void  {
        var width_view = dc.getWidth();
        var height_view = dc.getHeight();
        var width_device = System.getDeviceSettings().screenWidth;
        var height_device = System.getDeviceSettings().screenHeight;

        if (width_view < width_device - 10) {
            View.setLayout(Rez.Layouts.SmallLayout(dc));
            drawCompact = true; // Compact labels for small views
            drawGraph = false; // No graph in compact view
        }
        else {
            drawCompact = false; // Full length labels for wide views

            if (height_view < 150) { 
                View.setLayout(Rez.Layouts.WideLayout(dc));
                drawGraph = false; // No graph in compact view
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

        // Reset if nearly stopped
        if (speed < 1.0 || eTime > lastSample + 1.1) {
            _resetAll();
            gradeField.setData(0.0);
            lastSample = eTime;
            return blank_str;
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

        // Update rolling window 
        buffer[bufIndex] = { "altitude" => medianAlt, "distance" => speed };   // Replace oldest sample
        accWinDist += speed;                                                  // Accumulate distance with current movement
        bufIndex = (bufIndex + 1) % SAMPLE_WINDOW;                              // Iterate rolling buffer index
        accWinDist -= buffer[bufIndex]["distance"];

        if (bufIndex == 0) { bufFull = true; } // Buffer full, begin calculating slope

        if (accWinDist < 5 || !bufFull) {
            gradeField.setData(0.0);
            return blank_str;
        }

        // Compute raw & EMA grade
        dh = altitude - buffer[bufIndex]["altitude"];
        if (dh.abs() > MAX_ALT_JUMP) {
            // If altitude jump is too large, reset buffer and start over
            _resetAll();
            gradeField.setData(0.0);
            return blank_str;
        }
        
        computeLinearRegressionSlope(buffer);
        
        //  System.println(" - speed:      " + speed.format("%.2f") + "m/s | " + (speed*3.6).format("%.1f") + "kmh");
        //  System.println(" - acc dist:   " + accWinDist.format("%.3f"));
        //  System.println(" - elev gain:  " + dh.format("%.2f"));
        //  System.println(" - raw grade:  " + (100*grade_raw).format("%.3f"));
        //  System.println(" - grade:      " + (100*grade).format("%.3f"));

        // Accumulate distance in each zone
        var pctGrade = grade * 100.0;
        if (pctGrade >= THRESHOLD_LIGHT && quality > DIST_LOG_QUALITY) { distLight += speed; }
        if (pctGrade >= THRESHOLD_STEEP && quality > DIST_LOG_QUALITY) { distSteep += speed; }
        if (pctGrade > maxGrade && quality > MAX_LOG_QUALITY) { maxGrade = pctGrade; }

        // Format & export
        var value = pctGrade.format(str_format) + suffix;
        gradeField.setData(pctGrade);

        // Update session summary fields
        lightField.setData(distLight / 1000.0);
        steepField.setData(distSteep / 1000.0);
        maxField.setData(maxGrade); 

        //  System.println(" - max grade:  " + maxGrade.format("%.3f"));
        //  System.println(" - dist 5pct:  " + distLight.format("%.3f"));
        //  System.println(" - dist 10pct: " + distSteep.format("%.3f"));

        computeVAM(grade, buffer[bufIndex]["distance"]);

        return blank_str;
    }

    function computeEmaGrade(altitude) as Float {
        // Compute raw & EMA grade
        var dh = altitude - buffer[bufIndex]["altitude"];
        var grade_raw = dh / accWinDist;
        var alpha = EMA_ALPHA + EMA_ALT_ALPHA * dh.abs() / (1 + dh.abs());
        var ema_grade = alpha * grade_raw + (1 - alpha) * grade;

        return ema_grade;
    }

    function computeLinearRegressionSlope(samples as Array<Dictionary>) {
        var xVals = [];
        var dist = 0.0;
        calculating = true;

        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            var idx = (bufIndex + i) % SAMPLE_WINDOW;
            dist += samples[idx]["distance"];
            xVals.add(dist);
        }

        var sumX = 0.0, sumY = 0.0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            var idx = (bufIndex + i) % SAMPLE_WINDOW;
            sumY += samples[idx]["altitude"];
            sumX += xVals[i];
        }
        var meanX = sumX / SAMPLE_WINDOW;
        var meanY = sumY / SAMPLE_WINDOW;

        var covXY = 0.0, varX = 0.0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            var idx = (bufIndex + i) % SAMPLE_WINDOW;
            var dx = xVals[i] - meanX;
            var dy = samples[idx]["altitude"] - meanY;
            covXY += dx * dy;
            varX += dx * dx;
        }
        
        grade = (varX > 0.0) ? (covXY / varX) : 0.0;
        var sse = 0.0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            var idx = (bufIndex + i) % SAMPLE_WINDOW;
            var measAltDelta = samples[idx]["altitude"] - meanY;
            var AltDelta = grade * (xVals[i] - meanX);
            var res = (AltDelta - measAltDelta);

            sse += res*res;
        }

        if (varX > 0.0) {
            var sem = Math.sqrt((sse / (SAMPLE_WINDOW - 2)) / varX);
            quality = 0.005 / (0.005 + sem); // Quality measure based on standard error of the slope
        }
        else {
            quality = -1.0; // No valid data
            calculating = false; // We don't really have any data. This should never happen.
        }

        System.println("residual: " + sse.format("%.3f") + " | data quality: " + quality.format("%.3f"));
    }

    function computeVAM(grade as Float, speed as Float) as Float {
        // Compute VAM based on grade and speed
        if (grade > 0.0 && speed > 0.0) {
            vam = speed * grade * 3600; // in m/h
        }
        else { vam = 0.0; }

        if (grade > 0.05) {
            // Accumulate VAM for ascenting segments
            sumAscentVam += vam;
            samplesAscent++;

            vamAvg = sumAscentVam / samplesAscent;
        }

        vamField.setData(vam);
        vamAvgField.setData(vamAvg);

        return vam;
    }

    function onUpdate(dc as Dc) as Void 
    {
        

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
            value_curr_grade.setColor(textColor);
            value_curr_grade.setText((100 * grade).format(str_format) + suffix);
        }

        if (value_max_grade != null)
        {
            value_max_grade.setColor(textColor);
            value_max_grade.setText(maxGrade.format(str_format) + suffix);
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
            value_vam.setColor(textColor);
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

    hidden function _resetAll() {
        accWinDist   = 0.0;
        bufIndex = 0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            buffer[i] = { "altitude" => 0.0, "distance" => 0.0 }; 
        }
        rawAltitudes = [];
        bufFull = false;
        calculating = false;
    }
}