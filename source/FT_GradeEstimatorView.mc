import Toybox.Activity;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;
import Toybox.FitContributor;
import Toybox.Graphics;
import Toybox.Application;

class GradeEstimatorView extends WatchUi.DataField {
    // CONFIG
    var SAMPLE_WINDOW         = 35;   // buffer size (longer buffer)
    var MIN_GRADE_WINDOW      = 5;    // minimum samples for grade calc
    var MAX_GRADE_WINDOW     = 30;    // maximum samples for grade calc
    const SAMPLE_MISS_THRESHOLD = 5;    // how many samples can be missed
    var THRESHOLD_LIGHT    = 0.05;    // percent
    var THRESHOLD_STEEP    = 0.10;    // percent
    const FIELD_ID_GRADE     = 30;      // grade, REC
    const FIELD_ID_LIGHT     = 31;      // meters ≥ 5%, SESSION
    const FIELD_ID_STEEP     = 32;      // meters ≥10%, SESSION
    const FIELD_ID_MAXGRADE  = 33;      // max grade,   SESSION
    const FIELD_ID_VAM_GRAPH = 34;      // grade, REC
    const FIELD_ID_VAM_AVG   = 35;      // grade, REC
    const FIELD_ID_LAP_AVG   = 36;      // avg grade for laps
    const MAX_ALT_JUMP       = 10;
    const EWA_ALPHA          = 1;
    var DIST_LOG_QUALITY   = 0.33;    // Quality threshold for distance calculation
    var MAX_LOG_QUALITY    = 0.5;     // Quality threshold for maximum grade
    var LOG_SMOOTHED_GRADE = false; // Use smoothed grade for logging
    const RAMPAS_INHUMANAS_THRESHOLD = 0.15;
    enum { LAYOUT_SMALL, LAYOUT_WIDE, LAYOUT_LARGE }
    enum { UNIT_DIST_LONG, UNIT_DIST_SHORT, UNIT_VAM }
    const old_partnums      = ["006-B3121-00", "006-B3122-00", "006-B2713-00", "006-B3570-00", "006-B3095-00", "006-B4169-00"];

    const blank_str         = "-.-";
    const suffix            = "%";
    var str_format        = "%+.1f";
    const vam_str_format    = "%d";
    const update_annotation = "+";
    var filled_square     = "█";
    var empty_square      = "░";

    var unit_distance     = " km";
    var unit_vam          = " m/h";

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
    var ewa_grade as Float    = 0.0;
    var distLight as Float     = 0.0;  // meters at ≥5%
    var distSteep as Float     = 0.0;  // meters at ≥10%
    var maxGrade as Float      = 0.0;  // maximum grade encountered
    var lastSample as Float    = 0.0;
    var vam as Float           = 0.0;  // VAM in m/h
    var vamAvg as Float        = 0.0;  // Average VAM in m/h
    var numValid               = 0;
    var lastMaxGradeUpdateTime as Number = 0; // Last time max grade was updated

    var sumAscentVam as Float   = 0.0; // Sum of ascenting VAM (+5%)
    var samplesAscent as Number = 0; // Number of samples with ascenting VAM

    var lap_average_grade_sum as Float = 0.0;
    var lap_average_grade_count as Number = 0;

    // Adaptive window state
    var gradeWindowSize as Number = 10; // Start at 10, will be clamped between 6 and 20

    // FIT FIELDS
    var vamField, vamAvgField, gradeField, lightField, steepField, maxField, lapAvgGradeField;

    // UI
    var textColor as Number               = Graphics.COLOR_WHITE;
    var label_light_str as String         = "---"; // Label for light distance
    var label_steep_str as String         = "---"; // Label for steep distance
    var small_layout_draw_style as Number = 0;
    var layout as Number                  = 0;
    var isExploreUnit as Boolean          = false; 
    var isMetric                          = true;

    // STATUS STATE
    var calculating as Boolean  = false;
    var quality as Float        = 0.0;

    function getProgressBar(progress as Float, length as Number) as String {
        var bar = "";
        var numBlocks = Math.floor(progress * length);
        for (var i = 0; i < length; i++) {
            if (i < numBlocks) {
                bar += filled_square; // filled block
            } else {
                bar += empty_square; // empty block
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
                icon += filled_square;
            } else {
                icon += empty_square;
            }
        }
        return icon;
    }

    function getUpdatingValueAnnotatedString(isupdating as Boolean, s as String, annotation as String or Null, position as Number or Null, blinking as Boolean) as String {
        // Return input string with annotation indicating the value is currently being updated
        if (drawCompact() || isExploreUnit) { return s; }
        if (annotation == null) { annotation = update_annotation; } // Default annotation if none provided
        if (position == null) { position = 0; } // Default position is at the start

        if (isupdating && calculating) {
            var t = (Time.now().value()) % 2;
            // if (blinking && annotation.length() > 1 && t == 0) { annotation = annotation.substring(0,1); }
            if (t == 0 || !blinking) { 
                if (position == -1) { return annotation + s; }
                else if (position == 0) { return annotation + s + annotation; }
                else { return s + annotation; }
            }
            else { return s; }
            
        } else { return s; } // Can't be updating if not calculating
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
            c += " " + gradeWindowSize.format("%d") + "s";
            if (!drawCompact()) { c += "|" + numValid.format("%d") + "s";}
        } else if (bufIndex > 0) {
            c = str_buffering + " ";
            c += getProgressBar(bufIndex.toFloat() / MIN_GRADE_WINDOW, 19 - str_buffering.length());
        }
        else {
            c = str_no_data + " ";

            if (drawCompact()) { c = ""; }

            c += getRotatingIcon();
            c += " " + MIN_GRADE_WINDOW.format("%d") + "s|" + MAX_GRADE_WINDOW.format("%d") + "s|" + SAMPLE_WINDOW.format("%d") + "s";
        }
        return c;
    }

    function shouldAccLightDist() as Boolean { return (grade >= THRESHOLD_LIGHT && quality >= DIST_LOG_QUALITY); }
    function shouldAccSteepDist() as Boolean { return (grade >= THRESHOLD_STEEP && quality >= DIST_LOG_QUALITY); }
    function shouldAccAvgVAM() as Boolean {  return (grade >= THRESHOLD_LIGHT && quality >= DIST_LOG_QUALITY); }
    function shouldCalcMaxGrade() as Boolean { return (quality >= MAX_LOG_QUALITY && (gradeWindowSize > MIN_GRADE_WINDOW || gradeWindowSize == MAX_GRADE_WINDOW)); }
    function isMaxGradeUpdateRecent() as Boolean { return (Time.now().value() - lastMaxGradeUpdateTime < 20); }

    function drawCompact() as Boolean { return layout == LAYOUT_SMALL; }
    function drawGraph() as Boolean { return layout == LAYOUT_LARGE; }
    function drawCompactUnits() as Boolean { return (drawCompact() || isExploreUnit); }

    function getUnitString(unit as Number) as String {
        var out = "";

        if (isMetric) {
            switch (unit) {
                case UNIT_DIST_LONG: out = "km"; break;
                case UNIT_DIST_SHORT: out = "m"; break;
                case UNIT_VAM: out = "m/h"; break;
                default: break;
            }
        }
        else {
            switch (unit) {
                case UNIT_DIST_LONG: out = "mi"; break;
                case UNIT_DIST_SHORT: out = "ft"; break;
                case UNIT_VAM: out = "ft/h"; break;
                default: break;
            }
        }

        if (drawCompact() && (unit == UNIT_VAM || isExploreUnit)) { return ""; }
        else if (isExploreUnit || drawCompact()) { return out; }
        else { return " " + out;}
    }

    function getValueInLocalUnit(value as Float, type as Number) as Float {
        if (isMetric) { return value; }
        else {
            if (type == UNIT_DIST_LONG) { return value * 0.62; }
            else { return value * 3.28;}
        }
    }

    function initialize() {
        DataField.initialize();

        isMetric = System.getDeviceSettings().distanceUnits == System.UNIT_METRIC;

        // Read Settings
        updateSettings();

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

        // Lap Fields
        lapAvgGradeField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Lap_AvgGrade), FIELD_ID_LAP_AVG,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_LAP, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade)}
        );

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

    function determineLayout(dc as Dc) as Void {
        var width_view = dc.getWidth();
        var height_view = dc.getHeight();
        var width_device = System.getDeviceSettings().screenWidth;
        var height_device = System.getDeviceSettings().screenHeight;
        var partnum = System.getDeviceSettings().partNumber;

        if (old_partnums.indexOf(partnum) > -1) { isExploreUnit = true; }

        if (width_view < width_device / 2 + 10) { layout = LAYOUT_SMALL; }
        else {
            if (height_view < (height_device / 3) - 3) { layout = LAYOUT_WIDE; }
            else { layout = LAYOUT_LARGE; }
        }
    }

    public function updateSettings() {
        // Read Settings
        SAMPLE_WINDOW = Application.Properties.getValue("buffer_length");
        MIN_GRADE_WINDOW = Application.Properties.getValue("buffer_fit_min");
        MAX_GRADE_WINDOW = Application.Properties.getValue("buffer_fit_max");
        DIST_LOG_QUALITY = Application.Properties.getValue("threshold_log_dist");
        MAX_LOG_QUALITY = Application.Properties.getValue("threshold_log_max");
        LOG_SMOOTHED_GRADE = Application.Properties.getValue("save_smooth");
        THRESHOLD_LIGHT = Application.Properties.getValue("threshold_light") / 100.0;
        THRESHOLD_STEEP = Application.Properties.getValue("threshold_steep") / 100.0;

        small_layout_draw_style = Application.Properties.getValue("small_field_data");

        // Ensure the buffer is not too large or small
        if (SAMPLE_WINDOW > 180) { SAMPLE_WINDOW = 180; }
        else if (SAMPLE_WINDOW < 10) { SAMPLE_WINDOW = 10; }

        // Ensure minimum window size
        if (MIN_GRADE_WINDOW < 3) {
            MIN_GRADE_WINDOW = 3; 
        }

        // Ensure max window is at least min window
        if (MAX_GRADE_WINDOW < MIN_GRADE_WINDOW) {
            MAX_GRADE_WINDOW = MIN_GRADE_WINDOW; 
        }

        // Ensure buffer is at least as large as max grade window
        if (SAMPLE_WINDOW < MAX_GRADE_WINDOW) {
            SAMPLE_WINDOW = MAX_GRADE_WINDOW; // Ensure buffer is at least as large as max grade window
        }

        // Initialize strings
        str_buffering = WatchUi.loadResource(Rez.Strings.UI_Label_Status_Buffering);
        str_active = WatchUi.loadResource(Rez.Strings.UI_Label_Status_Active);
        str_no_data = WatchUi.loadResource(Rez.Strings.UI_Label_Status_NoData);
        
        updateLayoutDependentStrings();

        buffer = [];
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            buffer.add({ "altitude" => 0.0, "distance" => 0.0 });
        }
        _resetAll(true);
    }

    function updateLayoutDependentStrings() {
        if (layout == LAYOUT_SMALL && small_layout_draw_style != 2) {
            label_light_str = WatchUi.loadResource(Rez.Strings.UI_Label_Distance_Climb);
            label_steep_str = ">" + (THRESHOLD_STEEP * 100).format("%.1f") + "%";
        }
        else if (layout == LAYOUT_SMALL && small_layout_draw_style == 2) {
            label_light_str = WatchUi.loadResource(Rez.Strings.UI_Label_Distance_Climb);
        }
        else {
            label_light_str = WatchUi.loadResource(Rez.Strings.UI_Label_Distance_Light) + " >" + (THRESHOLD_LIGHT * 100).format("%.1f") + "%";
            label_steep_str = WatchUi.loadResource(Rez.Strings.UI_Label_Distance_Steep) + " >" + (THRESHOLD_STEEP * 100).format("%.1f") + "%";

            if (THRESHOLD_STEEP >= RAMPAS_INHUMANAS_THRESHOLD && !isExploreUnit) { label_steep_str = WatchUi.loadResource(Rez.Strings.UI_Label_RampasInhumanas) + "(+" + (THRESHOLD_STEEP * 100).format("%.1f") + "%)";}
            else if (isExploreUnit) {
                label_light_str = WatchUi.loadResource(Rez.Strings.UI_Label_Distance_Climb) + " >" + (THRESHOLD_LIGHT * 100).format("%.1f") + "%";
                label_steep_str = WatchUi.loadResource(Rez.Strings.UI_Label_Distance_Climb) + " >" + (THRESHOLD_STEEP * 100).format("%.1f") + "%";
            }
        }

        if (isExploreUnit) { // Fonts are too wide or not available
            filled_square = "|";
            empty_square = ".";
            str_format = "%.1f";

            unit_distance = "km";
            unit_vam = "m/h";
        }
    }

    function onLayout(dc as Dc) as Void  {
        determineLayout((dc));

        switch (layout) {
            default:
            case LAYOUT_SMALL:
                if (!isExploreUnit) { View.setLayout(Rez.Layouts.SmallLayout(dc)); }
                else { View.setLayout(Rez.Layouts.SmallLayoutExplore(dc)); } 
                break;
            case LAYOUT_WIDE: 
                if (!isExploreUnit) { View.setLayout(Rez.Layouts.WideLayout(dc)); } 
                else { View.setLayout(Rez.Layouts.WideLayoutExplore(dc)); } 
                break;
            case LAYOUT_LARGE: 
                if (!isExploreUnit) { View.setLayout(Rez.Layouts.LargeLayout(dc)); }
                else {  View.setLayout(Rez.Layouts.LargeLayoutExplore(dc)); } 
                break;
        }

        updateLayoutDependentStrings();
    }

    function onTimerLap() as Void {
        lap_average_grade_sum = 0.0;
        lap_average_grade_count = 0;
    }

    function compute(info) {
        // Assume exactly 1 Hz
        var speed    = (info has :currentSpeed) ? info.currentSpeed : null;
        var altitude = (info has :altitude) ? info.altitude : null;
        var eTime = (info has :elapsedTime) ? info.elapsedTime / 1000.0 : 0.0; 

        if (speed == null || altitude == null) { return blank_str; }

        var dt = eTime - lastSample;
        var sample_distance = speed * dt; // expect one second sample interval

        // System.println(dt + "," + speed + "," + altitude);

        // Reset if nearly stopped or if more than x samples missed (missing 1 sample should be rare)
        if (speed < 1.0 || eTime > lastSample + SAMPLE_MISS_THRESHOLD) {
            _resetAll(false);
            //gradeField.setData(0.0);
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

        if (prevMedianAlt != null && (medianAlt - prevMedianAlt).abs() > MAX_ALT_JUMP) {
            // If the altitude jumped too much, reset the buffer
            System.println("Altitude jump detected: " + (medianAlt - prevMedianAlt).abs() + " m, resetting buffer.");
            _resetAll(true);
            //gradeField.setData(0.0);
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
            //gradeField.setData(0.0);
            return blank_str;
        }

        // --- Adaptive window selection (new logic) ---
        // Compute main grade with current window size
        var mainGrade = computeWindowSlope(buffer, bufIndex, gradeWindowSize, SAMPLE_WINDOW);
        // Compute min grade with window size minimum (if enough samples)
        var minGrade = computeWindowSlope(buffer, bufIndex, MIN_GRADE_WINDOW, SAMPLE_WINDOW);
        
        // Compare and adjust window size for next call
        var gradeDiff = (mainGrade - minGrade).abs();
        if (gradeDiff > 0.02)  { gradeWindowSize -= 3; }
        else if (gradeDiff > 0.015) { gradeWindowSize -= 2; }
        else if (gradeDiff > 0.01)  { gradeWindowSize -= 1; } 
        else if (gradeDiff < 0.005 && gradeWindowSize <= MAX_GRADE_WINDOW / 2) 
                                    { gradeWindowSize += 1; }
        else if (gradeDiff < 0.0025){ gradeWindowSize += 1; }

        // Clamp window size between min and max, and not more than numValid
        if (gradeWindowSize < MIN_GRADE_WINDOW) { gradeWindowSize = MIN_GRADE_WINDOW; }
        if (gradeWindowSize > MAX_GRADE_WINDOW) { gradeWindowSize = MAX_GRADE_WINDOW; }
        if (gradeWindowSize > numValid) { gradeWindowSize = numValid; }

        // Use the main grade window for regression and display
        computeLinearRegressionSlope(buffer, bufIndex, gradeWindowSize);

        // Accumulate distance in each zone
        if (shouldAccLightDist()) { distLight += sample_distance; }
        if (shouldAccSteepDist()) { distSteep += sample_distance; }
        if (grade > maxGrade && shouldCalcMaxGrade()) { 
            maxGrade = grade;
            lastMaxGradeUpdateTime = Time.now().value(); // Update last max grade update time
        }

        lap_average_grade_sum += grade;
        lap_average_grade_count++;

        var pre_alpha = (gradeWindowSize.toFloat()) / (MAX_GRADE_WINDOW);
        var alpha = EWA_ALPHA * quality * quality * pre_alpha;
        ewa_grade = (1 - alpha) * ewa_grade + alpha * grade;

        //System.println(grade + "," + ewa_grade);

        // Export
        if (LOG_SMOOTHED_GRADE) { gradeField.setData(ewa_grade * 100); }
        else { gradeField.setData(grade * 100); }

        // Update session summary fields
        lightField.setData(distLight / 1000.0);
        steepField.setData(distSteep / 1000.0);
        maxField.setData(maxGrade * 100);
        lapAvgGradeField.setData(100 * lap_average_grade_sum / lap_average_grade_count);

        computeVAM(grade, speed);

        prevMedianAlt = medianAlt;

        //System.println(eTime + "," + info.elapsedDistance + ","  + speed + "," + altitude + "," + gradeWindowSize + "," + grade + "," + quality + "," + info.rawAmbientPressure + "," + info.ambientPressure);

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
            quality = 0.0; // No valid data
            calculating = false; // We don't really have any data. This should never happen.
        }
    }

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
        if (speed > 0.0) {
            vam = speed * grade * 3600; // in m/h
        }
        else { vam = 0.0; }

        if (shouldAccAvgVAM()) {
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

        if (drawCompact()) { // Determine which small fields to show
            setCompactVisible(dc);
        }

        setLabelColor(dc);

        drawDefaultView(dc);
        drawVAMFields(dc);
        drawStatusLabel(dc);

        View.onUpdate(dc);
        
        if (drawGraph()) { drawAltitudeBufferPlot(dc); }
    }

    function drawDefaultView(dc as Dc) as Void {
        var value_curr_grade = View.findDrawableById("value_curr_grade") as Text;
        var value_max_grade = View.findDrawableById("value_max_grade") as Text;
        var value_light = View.findDrawableById("value_light") as Text;
        var value_steep = View.findDrawableById("value_steep") as Text;
        var label_light = View.findDrawableById("label_light") as Text;
        var label_steep = View.findDrawableById("label_steep") as Text;
        
        if (value_curr_grade != null) {
            if (calculating || !drawCompact()) { value_curr_grade.setColor(textColor); }
            else { value_curr_grade.setColor(Graphics.COLOR_LT_GRAY); } // Set gray color if not active

            var print_grade = 100*grade;
            if (print_grade.abs() < 0.05) { value_curr_grade.setText("0.0" + suffix); }
            else { value_curr_grade.setText(print_grade.format(str_format) + suffix); }
        }

        if (value_max_grade != null) {
            value_max_grade.setColor(textColor);

            var str = (100*maxGrade).format(str_format);
            if (!drawCompact() || !isExploreUnit) { str += suffix; } 
            value_max_grade.setText(getUpdatingValueAnnotatedString(isMaxGradeUpdateRecent(), str, " !!", 1, false));
        }

        if (value_light != null) {
            value_light.setColor(textColor);
            var str = getValueInLocalUnit(distLight/1000, UNIT_DIST_LONG).format("%.1f") + getUnitString(UNIT_DIST_LONG);
            value_light.setText(getUpdatingValueAnnotatedString(shouldAccLightDist(), str, "↑", 0, false));
        }

        if (value_steep != null) {
            value_steep.setColor(textColor); 
            var str = getValueInLocalUnit(distSteep/1000, UNIT_DIST_LONG).format("%.1f") + getUnitString(UNIT_DIST_LONG);
            value_steep.setText(getUpdatingValueAnnotatedString(shouldAccSteepDist(), str, "↑", 0, false));
        }

        if (label_light != null) {
            label_light.setColor(textColor);
            label_light.setText(label_light_str);
        }

        if (label_steep != null) {
            label_steep.setColor(textColor);
            label_steep.setText(label_steep_str);
        }
    }

    function drawVAMFields(dc as Dc) as Void {
        var value_vam = View.findDrawableById("value_vam") as Text;
        var value_vam_avg = View.findDrawableById("value_vam_avg") as Text;

        if (value_vam != null) {
            value_vam.setColor(textColor);
            var str = getValueInLocalUnit(vam, UNIT_VAM).format(vam_str_format) + getUnitString(UNIT_VAM);
            value_vam.setText(str);
        }

        if (value_vam_avg != null) {
            value_vam_avg.setColor(textColor);
            var str = getValueInLocalUnit(vamAvg, UNIT_VAM).format(vam_str_format) + getUnitString(UNIT_VAM);
            value_vam_avg.setText(getUpdatingValueAnnotatedString(shouldAccAvgVAM(), str, "", -1, false));
        }
    }

    function setCompactVisible(dc as Dc) as Void {
        var hddn = [];
        var vis = [];

        switch (small_layout_draw_style) {
            default:
            case 0: // VAM
                hddn = ["value_max_grade", "label_max_grade", "value_light", "value_steep", "label_light", "label_steep"];
                vis = ["label_vam", "label_vam_avg", "value_vam", "value_vam_avg"];
                break;
            case 1: // Dist
                hddn = ["label_vam", "label_vam_avg", "value_vam", "value_vam_avg", "value_max_grade", "label_max_grade"];
                vis = ["value_light", "value_steep", "label_light", "label_steep"];
                break;
            case 2: // Climb + Max
                hddn = ["value_steep", "label_steep", "label_vam", "label_vam_avg", "value_vam", "value_vam_avg"];
                vis = ["label_light", "value_light", "label_max_grade", "value_max_grade"];
                break;
        }

        for (var i = 0; i < hddn.size(); i++) {
            var labelDrawable = View.findDrawableById(hddn[i]) as Text;
            if (labelDrawable != null) {
                labelDrawable.setVisible(false);
            }
        }

        for (var i = 0; i < vis.size(); i++) {
            var labelDrawable = View.findDrawableById(vis[i]) as Text;
            if (labelDrawable != null) {
                labelDrawable.setVisible(true);
            }
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

        var statusColor = textColor;
        // if (calculating && quality < DIST_LOG_QUALITY) {
        //     statusColor = Graphics.COLOR_RED; // Red if quality is low
        // } else if (calculating && quality < MAX_LOG_QUALITY) {
        //     statusColor = Graphics.COLOR_YELLOW; // Yellow for medium quality
        // }

        if (statusLabel != null) {
            statusLabel.setColor(statusColor);
            statusLabel.setText(getStatusString());
        }
    }

    function drawAltitudeBufferPlot(dc as Dc) as Void {
        // --- Plot area setup ---
        var width = dc.getWidth();
        var height = dc.getHeight();
        var margin = 3;
        var plotLeft = margin;
        var plotRight = width - margin;
        var plotTop = height / 2 + 3;
        var plotHeight = height - plotTop - margin;
        var plotBottom = plotTop + plotHeight;
        var plotWidth = plotRight - plotLeft;
        var offset = (System.getDeviceSettings().screenHeight * 0.035 + 2).toNumber();

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
            var xrange = maxX - minX;
            var yrange_data = maxY - minY;
            if (yrange_data < 0.1 * xrange)
            { 
                var midy = (maxY + minY) / 2.0;
                minY = midy - 0.05 * xrange; // Adjust Y range to ensure visibility
                maxY = midy + 0.05 * xrange; // Adjust Y
            }
            minY -= 1.0; // Add margin to Y
            maxY += 1.0; // Add margin to Y
            var yrange = maxY - minY;

            if (xrange < 50.0) {
                minX = maxX - 50.0; // Ensure we have a reasonable minimum range
                xrange = 50.0;
            }

            // --- Draw buffer as polyline ---
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(6);
            dc.setClip(plotLeft, plotTop, plotWidth, plotHeight);
            for (var j = 0; j < sampleCount - 1; j++) {
                var x1 = plotLeft + ((validDistances[j] - minX) / xrange) * plotWidth;
                var x2 = plotLeft + ((validDistances[j+1] - minX) / xrange) * plotWidth;
                var y1 = plotBottom - ((validAltitudes[j] - minY) / yrange) * plotHeight;
                var y2 = plotBottom - ((validAltitudes[j+1] - minY) / yrange) * plotHeight;
                dc.drawLine(x1, y1, x2, y2);
            }

            dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(plotLeft + plotWidth / 2, plotBottom - offset, Graphics.FONT_SYSTEM_TINY, "← " + getValueInLocalUnit(xrange, UNIT_DIST_SHORT).format("%.1f") + getUnitString(UNIT_DIST_SHORT) + " →", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(plotLeft + 3, plotTop + 3, Graphics.FONT_SYSTEM_TINY, "↕ " + getValueInLocalUnit(yrange, UNIT_DIST_SHORT).format("%.1f") + getUnitString(UNIT_DIST_SHORT), Graphics.TEXT_JUSTIFY_LEFT);

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

                if (quality > MAX_LOG_QUALITY) {
                    dc.setColor(Graphics.COLOR_DK_GREEN, Graphics.COLOR_TRANSPARENT);
                } else if (quality > DIST_LOG_QUALITY) {
                    dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
                } else {
                    dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
                }
                dc.setPenWidth(3);
                dc.drawLine(px1, py1, px2, py2);

                dc.drawText(plotLeft + plotWidth - 7, plotBottom - offset, Graphics.FONT_SYSTEM_TINY, "← " + getValueInLocalUnit(xEnd - xStart, UNIT_DIST_SHORT).format("%.1f") + getUnitString(UNIT_DIST_SHORT), Graphics.TEXT_JUSTIFY_RIGHT);
            }
        }

        // --- Draw plot area border ---
        dc.setColor(textColor, Graphics.COLOR_BLACK);
        dc.setPenWidth(2);
        dc.clearClip();
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