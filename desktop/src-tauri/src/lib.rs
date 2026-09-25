use serde_json::Value;
use std::{ffi::{c_char, c_void, CStr, CString}, sync::{OnceLock, atomic::{AtomicBool, Ordering}}};
use tauri::{Emitter, Manager};

static EXIT_ALLOWED: AtomicBool = AtomicBool::new(false);
static APP: OnceLock<tauri::AppHandle> = OnceLock::new();

extern "C" fn request_native_quit() {
    if let Some(app) = APP.get() { let app = app.clone();
        tauri::async_runtime::spawn(async move { let _ = show_settings(app, "quit".into(), None).await; }); }
}

extern "C" fn request_native_settings(section: *const c_char) {
    if section.is_null() { return; }
    let section = unsafe { CStr::from_ptr(section) }.to_string_lossy().into_owned();
    if let Some(app) = APP.get() {
        let app = app.clone();
        tauri::async_runtime::spawn(async move { let _ = show_settings(app, section, None).await; });
    }
}

#[cfg(target_os = "macos")]
extern "C" {
    fn rr_request(request: *const c_char, context: *mut c_void, callback: extern "C" fn(*mut c_void, *const c_char));
    fn rr_install_quit_guard(callback: extern "C" fn());
    fn rr_allow_quit();
    fn rr_install_ui_callback(callback: extern "C" fn(*const c_char));
}

extern "C" fn reply(context: *mut c_void, text: *const c_char) {
    // Swift calls once and lends the string only until this function returns.
    let sender = unsafe { Box::from_raw(context as *mut tokio::sync::oneshot::Sender<Result<Value, String>>) };
    let value = if text.is_null() { Err("native_empty_reply".into()) } else {
        serde_json::from_slice(unsafe { CStr::from_ptr(text) }.to_bytes()).map_err(|e| e.to_string())
    };
    let _ = sender.send(value);
}

#[tauri::command]
async fn native_request(request: Value) -> Result<Value, String> {
    #[cfg(target_os = "macos")]
    {
        let json = CString::new(request.to_string()).map_err(|e| e.to_string())?;
        let (sender, receiver) = tokio::sync::oneshot::channel::<Result<Value, String>>();
        let context = Box::into_raw(Box::new(sender)) as *mut c_void;
        unsafe { rr_request(json.as_ptr(), context, reply); }
        let result: Value = receiver.await.map_err(|e| e.to_string())??;
        if result["ok"] == true { Ok(result["value"].clone()) }
        else { Err(result["error"].as_str().unwrap_or("native_error").into()) }
    }
    #[cfg(not(target_os = "macos"))]
    { let _ = request; Err("unsupported_platform".into()) }
}

// Separate compact native hosts keep the desktop outside the panels clickable.
// DOM popovers cannot extend beyond their webview without a desktop-sized input window.
#[tauri::command]
async fn show_settings(app: tauri::AppHandle, section: String, anchor: Option<Vec<f64>>) -> Result<(), String> {
    let allowed = ["camera", "audio", "size", "script", "appearance", "results", "quit"];
    if !allowed.contains(&section.as_str()) { return Err("unknown_section".into()); }
    let state = native_request(serde_json::json!({"action":"status"})).await?;
    let window = app.get_webview_window("settings").ok_or("missing_settings")?;
    let main = app.get_webview_window("main").ok_or("missing_toolbar")?;
    let scale = main.scale_factor().map_err(|e|e.to_string())?;
    let origin = main.outer_position().map_err(|e|e.to_string())?.to_logical::<f64>(scale);
    let fallback = vec![origin.x+480.0,origin.y,40.0,40.0];
    let native_anchor = match section.as_str() { "camera"=>rect(&state["cameraAnchor"]), "size"=>rect(&state["regionToolbar"]), "script"=>rect(&state["promptToolbar"]), _=>None };
    let anchor = anchor.filter(|a|a.len()==4 && a.iter().all(|v|v.is_finite())).or_else(|| if state["overlaysVisible"]==true {native_anchor} else {None}).unwrap_or(fallback);
    let monitors = main.available_monitors().map_err(|e|e.to_string())?;
    let monitor = monitors.iter().find(|m| {
        let p=m.position().to_logical::<f64>(m.scale_factor()); let z=m.size().to_logical::<f64>(m.scale_factor());
        anchor[0]>=p.x && anchor[0]<p.x+z.width && anchor[1]>=p.y && anchor[1]<p.y+z.height
    });
    let bounds = monitor.map(|m| { let p=m.position().to_logical::<f64>(m.scale_factor()); let z=m.size().to_logical::<f64>(m.scale_factor()); [p.x+16.0,p.y+40.0,z.width-32.0,z.height-120.0] }).unwrap_or([0.0,40.0,1200.0,720.0]);
    let (w,h): (f64,f64) = match section.as_str() { "size"=>(400.0,740.0),"script"=>(480.0,560.0),"camera"=>(360.0,510.0),"audio"=>(360.0,410.0),"appearance"=>(360.0,320.0),_=>(460.0,520.0) };
    let (w,h)=(w.min(bounds[2]),h.min(bounds[3]));
    let x=(anchor[0]+anchor[2]/2.0-w/2.0).clamp(bounds[0],bounds[0]+bounds[2]-w);
    let y=if anchor[1]-h-12.0>=bounds[1] {anchor[1]-h-12.0} else {(anchor[1]+anchor[3]+12.0).min(bounds[1]+bounds[3]-h).max(bounds[1])};
    window.set_size(tauri::LogicalSize::new(w,h)).map_err(|e|e.to_string())?;
    window.set_position(tauri::LogicalPosition::new(x,y)).map_err(|e|e.to_string())?;
    window.emit("section", section).map_err(|e| e.to_string())?;
    window.show().map_err(|e| e.to_string())?;
    window.set_focus().map_err(|e| e.to_string())
}

fn rect(value:&Value)->Option<Vec<f64>> {
    let a=value.as_array()?;
    if a.len()!=4 {return None;}
    a.iter().map(|n|n.as_f64()).collect()
}

#[tauri::command]
async fn sync_overlays(app: tauri::AppHandle) -> Result<(),String> {
    let state=native_request(serde_json::json!({"action":"status"})).await?;
    for (label,key) in [("prompter","promptToolbar"),("region","regionToolbar")] {
        if let Some(window)=app.get_webview_window(label) {
            if state["overlaysVisible"]==true {
                if let Some(r)=rect(&state[key]) {
                    let b=rect(&state[if label=="prompter" {"promptVisibleFrame"} else {"visibleFrame"}]).unwrap_or(vec![0.0,0.0,1440.0,900.0]);
                    let x=r[0].clamp(b[0]+16.0,(b[0]+b[2]-r[2]-16.0).max(b[0]+16.0));
                    let y=r[1].clamp(b[1]+16.0,(b[1]+b[3]-r[3]-16.0).max(b[1]+16.0));
                    window.set_position(tauri::LogicalPosition::new(x,y)).map_err(|e|e.to_string())?;
                    if !window.is_visible().unwrap_or(false) { window.show().map_err(|e|e.to_string())?; }
                }
            } else { let _=window.hide(); }
        }
    }
    Ok(())
}

#[tauri::command]
fn close_settings(app:tauri::AppHandle, source:Option<String>) -> Result<(),String> {
    if let Some(window)=app.get_webview_window("settings") { window.hide().map_err(|e|e.to_string())?; }
    let label=source.filter(|v|["main","prompter","region"].contains(&v.as_str())).unwrap_or("main".into());
    if let Some(window)=app.get_webview_window(&label) { let _=window.set_focus(); let _=window.emit("restore-focus",()); }
    Ok(())
}

#[tauri::command]
async fn quit_app(app: tauri::AppHandle) -> Result<(), String> {
    let status = native_request(serde_json::json!({"action":"status"})).await?;
    if ["preparing", "countdown", "starting", "recording", "saving"].contains(&status["phase"].as_str().unwrap_or("")) {
        return Err("session_busy".into());
    }
    EXIT_ALLOWED.store(true, Ordering::SeqCst);
    #[cfg(target_os = "macos")]
    app.run_on_main_thread(|| unsafe { rr_allow_quit(); }).map_err(|e| e.to_string())?;
    app.exit(0);
    Ok(())
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![native_request, show_settings, close_settings, sync_overlays, quit_app])
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                // Keep the settings webview and its listeners alive for reopening.
                api.prevent_close();
                if window.label() == "settings" {
                    let _ = window.hide();
                } else {
                    let app=window.app_handle().clone();
                    tauri::async_runtime::spawn(async move { let _=show_settings(app,"quit".into(),None).await; });
                }
            }
        })
        .setup(|app| {
            let _ = APP.set(app.handle().clone());
            #[cfg(target_os = "macos")]
            unsafe { rr_install_quit_guard(request_native_quit); rr_install_ui_callback(request_native_settings); }
            if let Some(toolbar) = app.get_webview_window("main") {
                if let Some(monitor) = toolbar.current_monitor()? {
                    let scale = monitor.scale_factor();
                    let size = monitor.size().to_logical::<f64>(scale);
                    let origin = monitor.position().to_logical::<f64>(scale);
                    toolbar.set_position(tauri::LogicalPosition::new(origin.x + (size.width - 980.0) / 2.0, origin.y + size.height - 150.0))?;
                }
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("RecordReady initialization failed")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                if !EXIT_ALLOWED.load(Ordering::SeqCst) {
                    api.prevent_exit();
                    let app = app.clone();
        tauri::async_runtime::spawn(async move { let _ = show_settings(app, "quit".into(), None).await; });
                }
            }
        });
}
