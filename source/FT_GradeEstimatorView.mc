import Toybox.Activity;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;
import Toybox.FitContributor;
import Toybox.Graphics;
import Toybox.Application;

class GradeEstimatorView extends WatchUi.DataField {
    // CONFIG
    var SAMPLE_WINDOW as Number         = 35;   // buffer size (longer buffer)
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
    const FIELD_ID_MAXGRADE10S = 37;   // max grade sustained for 10s
    const FIELD_ID_MAXGRADE1MIN = 38;  // max grade sustained for 1min
    const FIELD_ID_MAXGRADE30MIN = 39; // max grade sustained for 30min
    const MAX_ALT_JUMP       = 10;
    const EWA_ALPHA          = 1;
    var DIST_LOG_QUALITY   = 0.33;    // Quality threshold for distance calculation
    var MAX_LOG_QUALITY    = 0.5;     // Quality threshold for maximum grade
    var LOG_SMOOTHED_GRADE = false; // Use smoothed grade for logging
    const RAMPAS_INHUMANAS_THRESHOLD = 0.15;
    enum { LAYOUT_SMALL, LAYOUT_WIDE, LAYOUT_LARGE, LAYOUT_FULLSCREEN }
    enum { UNIT_DIST_LONG, UNIT_DIST_SHORT, UNIT_VAM }
    enum { GRAPHMODE_BOTH, GRAPHMODE_BUFFER, GRAPHMODE_HISTOGRAM }
    const old_partnums      = ["006-B3121-00", "006-B3122-00", "006-B2713-00", "006-B3570-00", "006-B3095-00", "006-B4169-00"];
    const x50_partnum       = ["006-B4634-00", "006-B4440-00", "006-B4633-00"];
    const MAX_ALLOWED_GRADE = 0.3; 
    var GRADE_BIN_DIST       = 50.0;

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
    var prevSpeed as Float     = 0.0;

    var sumAscentVam as Float   = 0.0; // Sum of ascenting VAM (+5%)
    var samplesAscent as Number = 0; // Number of samples with ascenting VAM

    var binAccDist as Float = 0.0; 
    var binAccGrade as Float = 0.0;
    var binCount as Number = 0;

    var lap_average_grade_sum as Float = 0.0;
    var lap_average_grade_count as Number = 0;

    var climbTracker; // Instance of ClimbTracker to manage climbs

    var histogram; // Instance of Histogram to track grade distribution

    // Adaptive window state
    var gradeWindowSize as Number = 10; // Start at 10, will be clamped between 6 and 20

    // FIT FIELDS
    var vamField, vamAvgField, gradeField, lightField, steepField, maxField, lapAvgGradeField, maxGrade10sField, maxGrade1minField, maxGrade30minField;

    // UI
    var textColor as Number               = Graphics.COLOR_WHITE;
    var label_light_str as String         = "---"; // Label for light distance
    var label_steep_str as String         = "---"; // Label for steep distance
    var small_layout_draw_style as Number = 0;
    var layout as Number                  = 0;
    var graphmode as Number               = 1;
    var isExploreUnit as Boolean          = false; 
    var isx50Unit as Boolean              = false;
    var isMetric                          = true;
    var view_dimensions as Array<Number>  = [0,0];

    // STATUS STATE
    var calculating as Boolean  = false;
    var quality as Float        = 0.0;

    var DEBUG as Boolean       = false;

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
        var barlength = (drawCompact() ? 9 : 13) as Number;
        if (calculating) {
            c = str_active + " ";
            var progress = Math.sqrt((gradeWindowSize.toFloat() - MIN_GRADE_WINDOW + 1) / (MAX_GRADE_WINDOW - MIN_GRADE_WINDOW + 1));
            c += getProgressBar(progress, barlength);
            c += " " + gradeWindowSize.format("%d") + "s";
            if (!drawCompact()) { c += "|" + numValid.format("%d") + "s";}
        } else if (bufIndex > 0) {
            c = str_buffering + " ";
            c += getProgressBar(bufIndex.toFloat() / MIN_GRADE_WINDOW, 17 - str_buffering.length());
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
    function drawGraph() as Boolean { return layout >= LAYOUT_LARGE; }
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
        else if (unit == UNIT_VAM && isx50Unit) { return out; }
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
        System.println("AdaptiveGrade.initialize()");
        DataField.initialize();

        isMetric = System.getDeviceSettings().distanceUnits == System.UNIT_METRIC;

        // Read Settings
        updateSettings();

        gradeField = createField(
            WatchUi.loadResource(Rez.Strings.GC_ChartTitle_Grade), FIELD_ID_GRADE,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_RECORD, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade) }
        );

        vamField = createField(
            WatchUi.loadResource(Rez.Strings.GC_ChartTitle_VAM), FIELD_ID_VAM_GRAPH,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_RECORD, :units=>getUnitString(UNIT_VAM) }
        );

        // Session totals
        lightField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_Distance_Light), FIELD_ID_LIGHT,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>getUnitString(UNIT_DIST_LONG) }
        );

        steepField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_Distance_Steep), FIELD_ID_STEEP,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>getUnitString(UNIT_DIST_LONG) }
        );

        maxField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_Grade_Max), FIELD_ID_MAXGRADE,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade)}
        );

        vamAvgField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_AverageVAM), FIELD_ID_VAM_AVG,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>getUnitString(UNIT_VAM) }
        );

        maxGrade10sField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_10sGrade), FIELD_ID_MAXGRADE10S,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade)}
        );

        maxGrade1minField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_1minGrade), FIELD_ID_MAXGRADE1MIN,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade)}
        );

        maxGrade30minField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_30minGrade), FIELD_ID_MAXGRADE30MIN,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade)}
        );

        // Lap Fields
        lapAvgGradeField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Lap_AvgGrade), FIELD_ID_LAP_AVG,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_LAP, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade)}
        );

        initializeFields();
    }

    function initializeFields() {
        System.println("AdaptiveGrade.initializeFields()");

        gradeField.setData(0.0);
        vamField.setData(0.0);
        lightField.setData(0.0);
        steepField.setData(0.0);
        maxField.setData(0.0);
        vamAvgField.setData(0.0);
        lapAvgGradeField.setData(0.0);
        maxGrade10sField.setData(0.0);
        maxGrade1minField.setData(0.0);
        maxGrade30minField.setData(0.0);

        // Initialize rolling buffer
        buffer = [];
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            buffer.add({ "altitude" => -1000.0, "distance" => 0.0 });
        }
        rawAltitudes = [];
        _resetAll(true);
        grade      = 0.0;
        distLight  = 0.0;
        distSteep  = 0.0;

        climbTracker = new ClimbTracker(THRESHOLD_LIGHT);

        initializeGradeHistogram();
    }

    function initializeGradeHistogram() {
        System.println("AdaptiveGrade.initializeGradeHistogram()");

        histogram = new Histogram(1.0);
    }

    // TODO implement very narrow layout for 850 device (60 pixels high)
    function determineLayout(dc as Dc) as Void {
        if (DEBUG) { System.println("AdaptiveGrade.determineLayout()"); }
        var width_view = dc.getWidth();
        var height_view = dc.getHeight();
        var width_device = System.getDeviceSettings().screenWidth;
        var height_device = System.getDeviceSettings().screenHeight;
        var partnum = System.getDeviceSettings().partNumber;

        view_dimensions = [width_view, height_view];

        if (old_partnums.indexOf(partnum) > -1) { isExploreUnit = true; }
        else if (x50_partnum.indexOf(partnum) > -1) { isx50Unit = true; }

        var unitFactor = 1.0;
        if (isx50Unit) { unitFactor = 1.5; }

        if (width_view < width_device / 2 + 10) { layout = LAYOUT_SMALL; }
        else {
            if (height_view < 110 * unitFactor) { layout = LAYOUT_WIDE; }
            else if (height_view > height_device - 2) { layout = LAYOUT_FULLSCREEN; }
            else { layout = LAYOUT_LARGE; }
        }

        if (DEBUG) { 
            System.println("  Layout determined: " + layout); 
            System.println("  " + width_view + "x" + height_view + " on " + width_device + "x" + height_device + " device, partnum " + partnum + ", isExploreUnit=" + isExploreUnit);
        }
    }

    public function updateSettings() {
        System.println("AdaptiveGrade.updateSettings()");
        // Read Settings
        // Read and validate settings from properties
        var bufferLen = Application.Properties.getValue("buffer_length");
        if (bufferLen instanceof Number) { SAMPLE_WINDOW = bufferLen; }
        else { SAMPLE_WINDOW = 35; }

        var minWin = Application.Properties.getValue("buffer_fit_min");
        if (minWin instanceof Number) { MIN_GRADE_WINDOW = minWin; }
        else { MIN_GRADE_WINDOW = 5; }

        var maxWin = Application.Properties.getValue("buffer_fit_max");
        if (maxWin instanceof Number) { MAX_GRADE_WINDOW = maxWin; }
        else { MAX_GRADE_WINDOW = 30; }

        var distQuality = Application.Properties.getValue("threshold_log_dist");
        if (distQuality instanceof Float) { DIST_LOG_QUALITY = distQuality; }
        else { DIST_LOG_QUALITY = 0.33; }

        var maxQuality = Application.Properties.getValue("threshold_log_max");
        if (maxQuality instanceof Float) { MAX_LOG_QUALITY = maxQuality; }
        else { MAX_LOG_QUALITY = 0.5; }

        var saveSmooth = Application.Properties.getValue("save_smooth");
        if (saveSmooth instanceof Boolean) { LOG_SMOOTHED_GRADE = saveSmooth; }
        else { LOG_SMOOTHED_GRADE = false; }

        var thresholdLight = Application.Properties.getValue("threshold_light");
        if (thresholdLight instanceof Float) { THRESHOLD_LIGHT = thresholdLight / 100.0; }
        else { THRESHOLD_LIGHT = 0.05; }

        var thresholdSteep = Application.Properties.getValue("threshold_steep");
        if (thresholdSteep instanceof Float) { THRESHOLD_STEEP = thresholdSteep / 100.0; }
        else { THRESHOLD_STEEP = 0.10; }

        var debugEnabled = Application.Properties.getValue("debug_enabled");
        if (debugEnabled instanceof Boolean) { DEBUG = debugEnabled; }

        small_layout_draw_style = Application.Properties.getValue("small_field_data");
        if (!(small_layout_draw_style instanceof Number)) { small_layout_draw_style = 0; }

        graphmode = Application.Properties.getValue("graphmode");
        if (!(graphmode instanceof Number)) { graphmode = GRAPHMODE_BUFFER; }

        // Ensure the buffer is not too large or small
        if (SAMPLE_WINDOW > 180) { SAMPLE_WINDOW = 180; }
        else if (SAMPLE_WINDOW < 10) { SAMPLE_WINDOW = 10; }

        if (MIN_GRADE_WINDOW < 3) { MIN_GRADE_WINDOW = 3; }
        if (MAX_GRADE_WINDOW < MIN_GRADE_WINDOW) { MAX_GRADE_WINDOW = MIN_GRADE_WINDOW; }
        if (SAMPLE_WINDOW < MAX_GRADE_WINDOW) { SAMPLE_WINDOW = MAX_GRADE_WINDOW; }

        // Initialize strings
        str_buffering = WatchUi.loadResource(Rez.Strings.UI_Label_Status_Buffering);
        str_active = WatchUi.loadResource(Rez.Strings.UI_Label_Status_Active);
        str_no_data = WatchUi.loadResource(Rez.Strings.UI_Label_Status_NoData);
        
        updateLayoutDependentStrings();

        buffer = [];
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            buffer.add({ "altitude" => -1000.0, "distance" => 0.0 });
        }
        _resetAll(true);

        System.println("AdaptiveGrade Settings Changed:");
        System.println("  SAMPLE_WINDOW = " + SAMPLE_WINDOW);
        System.println("  MIN_GRADE_WINDOW = " + MIN_GRADE_WINDOW);
        System.println("  MAX_GRADE_WINDOW = " + MAX_GRADE_WINDOW);
        System.println("  DIST_LOG_QUALITY = " + DIST_LOG_QUALITY);
        System.println("  MAX_LOG_QUALITY = " + MAX_LOG_QUALITY);
        System.println("  LOG_SMOOTHED_GRADE = " + LOG_SMOOTHED_GRADE);
        System.println("  THRESHOLD_LIGHT = " + (THRESHOLD_LIGHT * 100).format("%.1f") + "%");
        System.println("  THRESHOLD_STEEP = " + (THRESHOLD_STEEP * 100).format("%.1f") + "%");
        System.println("  small_layout_draw_style = " + small_layout_draw_style);
        System.println("  graphmode = " + graphmode);
        System.println("  DEBUG = " + DEBUG);
    }

    function updateLayoutDependentStrings() {
        if (DEBUG) { System.println("AdaptiveGrade.updateLayoutDependentStrings()"); }
        if (layout == LAYOUT_SMALL && small_layout_draw_style < 2) {
            label_light_str = WatchUi.loadResource(Rez.Strings.UI_Label_Distance_Climb);
            label_steep_str = ">" + (THRESHOLD_STEEP * 100).format("%.1f") + "%";
        }
        else if (layout == LAYOUT_SMALL && small_layout_draw_style >= 2) {
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
                if (isx50Unit) { View.setLayout(Rez.Layouts.WideLayoutX50(dc)); }
                else if (isExploreUnit) { View.setLayout(Rez.Layouts.WideLayoutExplore(dc)); }
                else { View.setLayout(Rez.Layouts.WideLayout(dc)); } 
                break;
            case LAYOUT_LARGE:
                if (isx50Unit) { View.setLayout(Rez.Layouts.LargeLayoutX50(dc)); }
                else if (isExploreUnit) { View.setLayout(Rez.Layouts.LargeLayoutExplore(dc)); }
                else { View.setLayout(Rez.Layouts.LargeLayout(dc)); }
                break;
            case LAYOUT_FULLSCREEN:
                if (!isExploreUnit) { View.setLayout(Rez.Layouts.FullScreenLayout(dc)); }
                else { View.setLayout(Rez.Layouts.FullScreenLayoutExplore(dc)); }
                break;
        }

        updateLayoutDependentStrings();
    }

    function onTimerStart() as Void {
        System.println("AdaptiveGrade.onTimerStart()");
    }

    function onTimerLap() as Void {
        System.println("AdaptiveGrade.onTimerLap()");
        
        lap_average_grade_sum = 0.0;
        lap_average_grade_count = 0;
    }

    function onTimerReset() as Void {
        System.println("AdaptiveGrade.onTimerReset()");

        initializeFields();

        if (climbTracker.isClimbActive()) {
            climbTracker.saveClimb();
        }
    }

    function handleTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        if (DEBUG) { System.println("AdaptiveGrade.handleTap()"); }
        if (layout != LAYOUT_LARGE) { return false; }
        else if (clickEvent.getCoordinates()[1] < view_dimensions[1] / 2 - 5) { return false; } // Only if tapping in the lower half

        if (DEBUG) { System.println("AdaptiveGrade.handleTap() => true"); }
        graphmode = (graphmode + 1) % 3;
        WatchUi.requestUpdate();
        return true;
    }

    function onTimerStop() as Void {
        System.println("AdaptiveGrade.onTimerStop()");

        writeSessionFields();
    }

    function writeSessionFields() as Void {
        lightField.setData(getValueInLocalUnit(distLight / 1000.0, UNIT_DIST_LONG));
        steepField.setData(getValueInLocalUnit(distSteep / 1000.0, UNIT_DIST_LONG));
        maxField.setData(maxGrade * 100.0);
        vamAvgField.setData(getValueInLocalUnit(vamAvg, UNIT_VAM));
        maxGrade10sField.setData(histogram.getHighGradeForTime(10));
        maxGrade1minField.setData(histogram.getHighGradeForTime(60));
        maxGrade30minField.setData(histogram.getHighGradeForTime(1800));
    }

    function compute(info  as Activity.Info) as Number {
        if (info == null) { 
            if (DEBUG) { System.println("AdaptiveGrade.compute() info is null"); }
            return 0; 
        }
        var speed    = (info has :currentSpeed) ? info.currentSpeed : null;
        var altitude = (info has :altitude) ? info.altitude : null;
        var eTime = (info has :elapsedTime) ? info.elapsedTime / 1000.0 : 0.0; 

        if (speed == null || altitude == null || !(eTime instanceof Float)) {
            if (DEBUG) { System.println("AdaptiveGrade.compute() missing data: spd:" + speed + " alt:" + altitude + " t:" + eTime); }
            return 0; 
        }

        var dt = eTime - lastSample;
        var sample_distance = speed * dt; // expect one second sample interval

        // Reset if nearly stopped, if more than x samples missed or if timer is not running
        if (sample_distance < 0.33 || dt > SAMPLE_MISS_THRESHOLD) {
            if (DEBUG) { System.println("AdaptiveGrade.compute() stop or sample gap detected: spd: " + speed.format("%.2f") + " dt: " + dt.format("%.2f")); }
            _resetAll(false);
            lastSample = eTime;
            return 0;
        }

        lastSample = eTime;

        // Median filter for altitude using only real raw values
        // rawAltitudes.add(altitude);
        // if (rawAltitudes.size() > 3) { rawAltitudes = rawAltitudes.slice(1, rawAltitudes.size()); }
        var medianAlt = altitude;
        // if (rawAltitudes.size() == 3) {
        //     medianAlt = median3(rawAltitudes[0], rawAltitudes[1], rawAltitudes[2]);
        // } 

        if (prevMedianAlt != null && (medianAlt - prevMedianAlt).abs() > MAX_ALT_JUMP) {
            // If the altitude jumped too much, reset the buffer
            if (DEBUG) { System.println("AdaptiveGrade.compute() altitude jump detected: " + (medianAlt - prevMedianAlt).abs().format("%.1f") + " m, resetting buffer."); }
            _resetAll(true);
            lastSample = eTime;
            return 0;
        }

        // Update rolling window
        buffer[bufIndex] = { "altitude" => medianAlt, "distance" => sample_distance }; // Replace oldest sample
        bufIndex = (bufIndex + 1) % SAMPLE_WINDOW; // Iterate rolling buffer index

        // Track how many valid samples are in the buffer
        numValid = 0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            if (buffer[i]["altitude"] > -500.0) { numValid++; }
        }

        if (numValid < MIN_GRADE_WINDOW) { 
            if (DEBUG) { System.println("AdaptiveGrade.compute() buffer too short: " + numValid + " / " + MIN_GRADE_WINDOW); }
            return 0; 
        }

        if (DEBUG) { System.println("AdaptiveGrade.compute() window:" + gradeWindowSize + " buffer:" + numValid + " alt=" + medianAlt.format("%.1f") + " d=" + sample_distance.format("%.1f")); }

        // --- Adaptive window selection (new logic) ---
        // Compute main grade with current window size
        var mainGrade = computeWindowSlope(buffer, bufIndex, gradeWindowSize, SAMPLE_WINDOW);
        // Compute min grade with window size minimum (if enough samples)
        var minGrade = computeWindowSlope(buffer, bufIndex, MIN_GRADE_WINDOW, SAMPLE_WINDOW);
        
        // Compare and adjust window size for next call
        var gradeDiff = (mainGrade - minGrade).abs();
        if (gradeDiff > 0.02)  { gradeWindowSize -= 3; }
        else if (gradeDiff > 0.015) { gradeWindowSize -= 2; }
        else if (gradeDiff > 0.0075)  { gradeWindowSize -= 1; } 
        else if (gradeDiff < 0.004 && gradeWindowSize <= MAX_GRADE_WINDOW / 2) 
                                    { gradeWindowSize += 1; }
        else if (gradeDiff < 0.002){ gradeWindowSize += 1; }

        // Clamp window size between min and max, and not more than numValid
        if (gradeWindowSize < MIN_GRADE_WINDOW) { gradeWindowSize = MIN_GRADE_WINDOW; }
        if (gradeWindowSize > MAX_GRADE_WINDOW) { gradeWindowSize = MAX_GRADE_WINDOW; }
        if (gradeWindowSize > numValid) { gradeWindowSize = numValid; }

        // Use the main grade window for regression and display
        computeLinearRegressionSlope(buffer, bufIndex, gradeWindowSize);
        if (grade > MAX_ALLOWED_GRADE) { grade = MAX_ALLOWED_GRADE;}
        else if (grade < -MAX_ALLOWED_GRADE) { grade = -MAX_ALLOWED_GRADE; }

        computeVAM(grade, speed);

        histogram.addData(grade * 100, quality);
        if (histogram.shouldUpdate()) { histogram.compute(); }

        // Accumulate distance in each zone if above threshold and quality is good enough
        if (shouldAccLightDist()) { distLight += sample_distance; }
        if (shouldAccSteepDist()) { distSteep += sample_distance; }
        if (grade > maxGrade && shouldCalcMaxGrade()) { 
            maxGrade = grade;
            lastMaxGradeUpdateTime = Time.now().value(); // Update last max grade update time. For UI indication only.
        }

        // Calculate average lap grade (time spent at grade)
        lap_average_grade_sum += grade;
        lap_average_grade_count++;
        lapAvgGradeField.setData(100 * lap_average_grade_sum / lap_average_grade_count);

        // Log current grade
        if (LOG_SMOOTHED_GRADE) { binnedGradeLogging(sample_distance); }
        else { gradeField.setData(grade * 100); }

        prevMedianAlt = medianAlt;

        return 1;
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

    function binnedGradeLogging(sample_distance as Float) as Void {
        binAccDist += sample_distance;
        binAccGrade += grade;
        binCount++;
        
        if (binAccDist >= GRADE_BIN_DIST) {
            var avgBinGrade = binAccGrade / binCount;
            gradeField.setData(avgBinGrade * 100);
            binAccGrade = 0.0;
            binAccDist = 0.0;
            binCount = 0;
        }
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
        
        if (drawGraph()) { 

            if (graphmode == GRAPHMODE_BOTH || layout == LAYOUT_FULLSCREEN) { 
                drawHistogramPlot(dc); 
                drawAltitudeBufferPlot(dc); 
            }
            else if (graphmode == GRAPHMODE_BUFFER) { drawAltitudeBufferPlot(dc);  }
            else if (graphmode == GRAPHMODE_HISTOGRAM) { drawHistogramPlot(dc);  }
        }
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

            var str = (100*maxGrade).format("%.1f");
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
        var value_vam_right = View.findDrawableById("value_vam_right") as Text;
        var value_vam_avg = View.findDrawableById("value_vam_avg") as Text;

        if (value_vam != null) {
            value_vam.setColor(textColor);
            var str = getValueInLocalUnit(vam, UNIT_VAM).format(vam_str_format) + getUnitString(UNIT_VAM);
            value_vam.setText(str);
        }

        if (value_vam_right != null) {
            value_vam_right.setColor(textColor);
            var str = getValueInLocalUnit(vam, UNIT_VAM).format(vam_str_format) + getUnitString(UNIT_VAM);
            value_vam_right.setText(str);
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
                hddn = ["value_max_grade", "label_max_grade", "value_light", "value_steep", "label_light", "label_steep", "label_vam_right", "value_vam_right"];
                vis = ["label_vam", "label_vam_avg", "value_vam", "value_vam_avg"];
                break;
            case 1: // Dist
                hddn = ["label_vam", "label_vam_avg", "value_vam", "value_vam_avg", "value_max_grade", "label_max_grade", "label_vam_right", "value_vam_right"];
                vis = ["value_light", "value_steep", "label_light", "label_steep"];
                break;
            case 2: // Climb + Max
                hddn = ["value_steep", "label_steep", "label_vam", "label_vam_avg", "value_vam", "value_vam_avg", "label_vam_right", "value_vam_right"];
                vis = ["label_light", "value_light", "label_max_grade", "value_max_grade"];
                break;
            case 3: // Climb + VAM
                hddn = ["value_steep", "label_steep", "label_max_grade", "label_vam_avg", "value_max_grade", "value_vam_avg", "label_vam", "value_vam"];
                vis = ["label_light", "value_light", "label_vam_right", "value_vam_right" ];
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
        var labels = ["label_curr_grade", "label_max_grade", "label_light", "label_steep", "label_vam", "label_vam_avg", "label_vam_right"];
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
        var width = view_dimensions[0];
        var height = view_dimensions[1];
        // --- Plot area setup ---
        var margin = 3;
        var plotLeft = margin;
        var plotRight = width - margin;
        var plotTop = height / 2 + 3;
        var plotHeight = height - plotTop - margin;

        if (layout == LAYOUT_FULLSCREEN) { 
            plotTop = height * 0.20f;
            plotHeight = height * 0.40f - margin;
        }
        else if (graphmode == GRAPHMODE_BOTH) { // Draw plots on top of each other... ehh
            plotTop = height / 2 + 3;
            plotHeight = height - plotTop - margin - 12;

            if (isx50Unit) { plotHeight -= 8; } // More space needed for X50 units
        }

        var plotBottom = plotTop + plotHeight;
        var plotWidth = plotRight - plotLeft + 1;

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
            dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
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
            dc.drawText(plotLeft + plotWidth / 2, plotTop + 3, Graphics.FONT_SYSTEM_TINY, "← " + getValueInLocalUnit(xrange, UNIT_DIST_SHORT).format("%.1f") + getUnitString(UNIT_DIST_SHORT) + " →", Graphics.TEXT_JUSTIFY_CENTER);
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

                dc.drawText(plotLeft + plotWidth - 7, plotTop + 3, Graphics.FONT_SYSTEM_TINY, "← " + getValueInLocalUnit(xEnd - xStart, UNIT_DIST_SHORT).format("%.1f") + getUnitString(UNIT_DIST_SHORT), Graphics.TEXT_JUSTIFY_RIGHT);
            }
        }
        else {
            dc.drawText(plotLeft + plotWidth / 2, plotBottom - plotHeight / 2 + 2, Graphics.FONT_SYSTEM_TINY, WatchUi.loadResource(Rez.Strings.UI_Label_Graph_NoData), Graphics.TEXT_JUSTIFY_CENTER|Graphics.TEXT_JUSTIFY_VCENTER);
        }

        // --- Draw plot area border ---
        dc.setColor(textColor, Graphics.COLOR_BLACK);
        dc.setPenWidth(2);
        dc.clearClip();
        dc.drawRectangle(plotLeft, plotTop, plotWidth, plotHeight);
    }

    function drawHistogramPlot(dc as Dc) as Void {
        var width = view_dimensions[0];
        var height = view_dimensions[1];
        // --- Plot area setup ---
        var margin = 3;
        var plotLeft = margin;
        var plotRight = width - margin;
        var plotTop = height / 2 + 3;
        var plotHeight = height - plotTop - margin - 12;

        if (isx50Unit) { plotHeight -= 8; } // More space needed for X50 units

        if (layout == LAYOUT_FULLSCREEN) { 
            plotTop = height * 0.60f + margin;
            plotHeight = height * 0.38f - margin - 12;  
        }

        var plotBottom = plotTop + plotHeight;
        var plotWidth = plotRight - plotLeft + 1;
        var offset = 9;
        if (isExploreUnit) { offset -= 2; }
        else if (isx50Unit) { offset += 6; }

        if (histogram.computed) {
            var range = histogram.computedSampledBinRange; // [min, max] of the histogram bins indexes
            var values = histogram.computedHistogramForRange; // Array of normalized counts (0.0 to 1.0)

            var maxVal = 0.0;
            for (var i = 0; i < values.size(); i++) {
                if (values[i] > maxVal) { maxVal = values[i]; }
            }
            maxVal *= 1.1; // Add 10% headroom

            var tickGrades = 1;
            if (range[1] - range[0] >= 35) { tickGrades = 10; }
            else if (range[1] - range[0] >= 18) { tickGrades = 5; }
            else if (range[1] - range[0] >= 10) { tickGrades = 2; }

            // --- Draw histogram as vertical bars ---
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(1);

            var binWidth = (plotWidth - 2) / values.size();
            var currBin = histogram.getBinIndex(grade * 100) - range[0]; // Current grade bin index
            for (var j = 0; j < values.size(); j++) {
                var grade = histogram.getGradeForBin(j + range[0]) - 0.5f;
                var x1 = plotLeft + 2 + j * binWidth;
                var x2 = x1 + binWidth - 1;
                var y1 = plotBottom;
                var y2 = plotBottom - values[j] / maxVal * plotHeight;

                if (grade.toNumber() % tickGrades == 0 && j != 0) {

                    dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                    dc.drawLine(x1, plotBottom, x1, plotTop);

                    dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
                    dc.drawText(x1 + 1, plotBottom + offset, Graphics.FONT_SYSTEM_TINY, grade.format("%.0f") + "%", Graphics.TEXT_JUSTIFY_CENTER|Graphics.TEXT_JUSTIFY_VCENTER);
                }

                if (j == currBin) { dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT); }
                else { dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT); }

                dc.fillRectangle(x1 + 1, y2, x2 - x1, y1 - y2);
            }
        }
        else {
            dc.drawText(plotLeft + plotWidth / 2, plotBottom - plotHeight / 2 + 2, Graphics.FONT_SYSTEM_TINY, WatchUi.loadResource(Rez.Strings.UI_Label_Graph_NoData), Graphics.TEXT_JUSTIFY_CENTER|Graphics.TEXT_JUSTIFY_VCENTER);
        }

        // --- Draw plot area border ---
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawRectangle(plotLeft, plotTop, plotWidth, plotHeight);
    }

    hidden function _resetAll(deleteAll as Boolean) as Void {
        bufIndex = 0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            buffer[i] = { "altitude" => -1000.0, "distance" => 0.0 }; 
        }
        rawAltitudes = [];
        calculating = false;
        gradeWindowSize = MIN_GRADE_WINDOW; // Reset adaptive window size
        prevMedianAlt = null; // Reset previous median altitude
        prevSpeed = 0.0;
    }
}