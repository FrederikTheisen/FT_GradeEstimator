import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class GradeEstimatorApp extends Application.AppBase {

    var view as GradeEstimatorView or Null;

    function initialize() {
        AppBase.initialize();
    }

    // onStart() is called on application start up
    function onStart(state as Dictionary?) as Void {
    }

    // onStop() is called when your application is exiting
    function onStop(state as Dictionary?) as Void {
    }

    function onSettingsChanged() as Void {
        AppBase.onSettingsChanged();

        view.updateSettings();
    }

    // Return the initial view of your application here
    function getInitialView()  {
        view = new GradeEstimatorView();

        return [ view ];
    }
}

function getApp() as GradeEstimatorApp {
    return Application.getApp() as GradeEstimatorApp;
}