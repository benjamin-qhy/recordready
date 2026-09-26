mod window_preferences;
use window_preferences::Point;
use serde_json::Value;
use std::{ffi::{c_char, c_void, CStr, CString}, sync::{OnceLock, atomic::{AtomicBool, Ordering}}};
use tauri::{Emitter, Manager};

static LAYOUT_READY: AtomicBool = AtomicBool::new(false);
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
    let allowed = ["camera", "audio", "appearance", "saveLocation", "results", "quit"];
    if !allowed.contains(&section.as_str()) { return Err("unknown_section".into()); }
    let state = native_request(serde_json::json!({"action":"status"})).await?;
    let window = app.get_webview_window("settings").ok_or("missing_settings")?;
    let main = app.get_webview_window("main").ok_or("missing_toolbar")?;
    let scale = main.scale_factor().map_err(|e|e.to_string())?;
    let origin = main.outer_position().map_err(|e|e.to_string())?.to_logical::<f64>(scale);
    let fallback = vec![origin.x+350.0,origin.y,32.0,32.0];
    let native_anchor = match section.as_str() { "camera"=>rect(&state["cameraAnchor"]), _=>None };
    let anchor = anchor.filter(|a|a.len()==4 && a.iter().all(|v|v.is_finite())).or_else(|| if state["overlaysVisible"]==true {native_anchor} else {None}).unwrap_or(fallback);
    let saved=window_preferences::get(&format!("settings:{section}"));
    let target=saved.unwrap_or(Point{x:anchor[0],y:anchor[1]});
    let monitors = main.available_monitors().map_err(|e|e.to_string())?;
    let monitor = monitors.iter().find(|m| {
        let p=m.position().to_logical::<f64>(m.scale_factor()); let z=m.size().to_logical::<f64>(m.scale_factor());
        target.x>=p.x && target.x<p.x+z.width && target.y>=p.y && target.y<p.y+z.height
    });
    let monitor=monitor.or_else(||monitors.iter().find(|m|m.position().x==0&&m.position().y==0)).or_else(||monitors.first());
    let bounds = monitor.map(|m| { let area=m.work_area();let p=area.position.to_logical::<f64>(m.scale_factor()); let z=area.size.to_logical::<f64>(m.scale_factor()); [p.x+12.0,p.y+12.0,z.width-24.0,z.height-24.0] }).unwrap_or([0.0,40.0,1200.0,720.0]);
    let (w,h): (f64,f64) = match section.as_str() { "appearance"=>(240.0,350.0),"saveLocation"=>(240.0,290.0),"quit"=>(340.0,285.0),_=>(380.0,410.0) };
    let (w,h)=(w.min(bounds[2]),h.min(bounds[3]));
    let x=(anchor[0]+anchor[2]/2.0-w/2.0).clamp(bounds[0],bounds[0]+bounds[2]-w);
    let y=if anchor[1]-h-12.0>=bounds[1] {anchor[1]-h-12.0} else {(anchor[1]+anchor[3]+12.0).min(bounds[1]+bounds[3]-h).max(bounds[1])};
    let point=window_preferences::clamp(saved.unwrap_or(Point{x,y}),[w,h],bounds);
    let (x,y)=(point.x,point.y);
    window_preferences::section(&section);
    window.set_size(tauri::LogicalSize::new(w,h)).map_err(|e|e.to_string())?;
    window.set_position(tauri::LogicalPosition::new(x,y)).map_err(|e|e.to_string())?;
    window.emit("section", section).map_err(|e| e.to_string())?;
    window.emit("settings-anchor", serde_json::json!({"side":if y<anchor[1] {"bottom"} else {"top"},"x":(anchor[0]+anchor[2]/2.0-x).clamp(24.0,w-24.0)})).map_err(|e|e.to_string())?;
    window.show().map_err(|e| e.to_string())?;
    window.set_focus().map_err(|e| e.to_string())
}

fn rect(value:&Value)->Option<Vec<f64>> {
    let a=value.as_array()?;
    if a.len()!=4 {return None;}
    a.iter().map(|n|n.as_f64()).collect()
}

fn recording_toolbar_position(region:[f64;4],toolbar:[f64;2],bounds:[f64;4])->[f64;2] {
    let gap=12.0;
    let centered_x=(region[0]+(region[2]-toolbar[0])/2.0).clamp(bounds[0],(bounds[0]+bounds[2]-toolbar[0]).max(bounds[0]));
    let centered_y=(region[1]+(region[3]-toolbar[1])/2.0).clamp(bounds[1],(bounds[1]+bounds[3]-toolbar[1]).max(bounds[1]));
    let candidates=[
        [centered_x,region[1]-toolbar[1]-gap],
        [centered_x,region[1]+region[3]+gap],
        [region[0]-toolbar[0]-gap,centered_y],
        [region[0]+region[2]+gap,centered_y],
    ];
    candidates.into_iter().find(|p|p[0]>=bounds[0]&&p[1]>=bounds[1]&&p[0]+toolbar[0]<=bounds[0]+bounds[2]&&p[1]+toolbar[1]<=bounds[1]+bounds[3])
        .unwrap_or([centered_x,(bounds[1]+bounds[3]-toolbar[1]).max(bounds[1])])
}

#[tauri::command]
fn place_recording_toolbar(app:tauri::AppHandle,region:Vec<f64>)->Result<(),String>{
    if region.len()!=4||!region.iter().all(|v|v.is_finite()) {return Err("invalid_region".into());}
    let window=app.get_webview_window("main").ok_or("missing_toolbar")?;
    let scale=window.scale_factor().map_err(|e|e.to_string())?;
    let size=window.outer_size().map_err(|e|e.to_string())?.to_logical::<f64>(scale);
    let monitors=window.available_monitors().map_err(|e|e.to_string())?;
    let monitor=monitors.iter().find(|m|{let o=m.position().to_logical::<f64>(m.scale_factor());let z=m.size().to_logical::<f64>(m.scale_factor());region[0]>=o.x&&region[0]<o.x+z.width&&region[1]>=o.y&&region[1]<o.y+z.height}).or_else(||monitors.first()).ok_or("missing_display")?;
    let area=monitor.work_area();let o=area.position.to_logical::<f64>(monitor.scale_factor());let z=area.size.to_logical::<f64>(monitor.scale_factor());
    let p=recording_toolbar_position([region[0],region[1],region[2],region[3]],[size.width,size.height],[o.x+8.0,o.y+8.0,z.width-16.0,z.height-16.0]);
    window.set_position(tauri::LogicalPosition::new(p[0],p[1])).map_err(|e|e.to_string())
}

#[tauri::command]
async fn sync_overlays(app: tauri::AppHandle) -> Result<(),String> {
    let state=native_request(serde_json::json!({"action":"status"})).await?;
    for (label,key) in [("prompter","promptToolbar"),("region","regionToolbar")] {
        if let Some(window)=app.get_webview_window(label) {
            if state[if label=="prompter" {"promptVisible"} else {"overlaysVisible"}]==true && !(label=="region" && ["starting","recording","paused","saving"].contains(&state["phase"].as_str().unwrap_or(""))) {
                if let Some(r)=rect(&state[key]) {
                    let b=rect(&state[if label=="prompter" {"promptVisibleFrame"} else {"regionToolbarVisibleFrame"}]).unwrap_or(vec![0.0,0.0,1440.0,900.0]);
                    let inset=0.0;
                    let x=r[0].clamp(b[0]+inset,(b[0]+b[2]-r[2]-inset).max(b[0]+inset));
                    let y=r[1].clamp(b[1]+inset,(b[1]+b[3]-r[3]-inset).max(b[1]+inset));
                    window.set_size(tauri::LogicalSize::new(r[2],r[3])).map_err(|e|e.to_string())?;
                    window.set_position(tauri::LogicalPosition::new(x,y)).map_err(|e|e.to_string())?;
                    if !window.is_visible().unwrap_or(false) {
                        window.show().map_err(|e|e.to_string())?;
                    }
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
    if ["preparing", "countdown", "starting", "recording", "paused", "saving"].contains(&status["phase"].as_str().unwrap_or("")) {
        return Err("session_busy".into());
    }
    window_preferences::flush();
    EXIT_ALLOWED.store(true, Ordering::SeqCst);
    #[cfg(target_os = "macos")]
    app.run_on_main_thread(|| unsafe { rr_allow_quit(); }).map_err(|e| e.to_string())?;
    app.exit(0);
    Ok(())
}


#[tauri::command]
async fn request_exit(app: tauri::AppHandle) -> Result<(), String> {
    show_settings(app,"quit".into(),None).await
}

#[tauri::command]
fn resize_settings_content(app:tauri::AppHandle,section:String,height:f64)->Result<(),String>{
    if !["appearance","saveLocation"].contains(&section.as_str()) || !height.is_finite(){return Err("invalid_size".into());}
    let window=app.get_webview_window("settings").ok_or("missing_settings")?;
    let scale=window.scale_factor().map_err(|e|e.to_string())?;
    if let Some(m)=window.current_monitor().map_err(|e|e.to_string())? {
        let area=m.work_area();
        let origin=area.position.to_logical::<f64>(m.scale_factor());
        let size=area.size.to_logical::<f64>(m.scale_factor());
        let h=height.clamp(220.0,(size.height-24.0).max(220.0));
        let p=window.outer_position().map_err(|e|e.to_string())?.to_logical::<f64>(scale);
        window.set_size(tauri::LogicalSize::new(240.0,h)).map_err(|e|e.to_string())?;
        window.set_position(tauri::LogicalPosition::new(p.x.clamp(origin.x+12.0,(origin.x+size.width-252.0).max(origin.x+12.0)),p.y.clamp(origin.y+12.0,(origin.y+size.height-h-12.0).max(origin.y+12.0)))).map_err(|e|e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn resize_toolbar(app:tauri::AppHandle, width:f64, height:f64) -> Result<(),String> {
    if !width.is_finite() || !height.is_finite() {return Err("invalid_size".into());}
    let window=app.get_webview_window("main").ok_or("missing_toolbar")?;
    let monitor=window.current_monitor().map_err(|e|e.to_string())?;
    let scale=window.scale_factor().map_err(|e|e.to_string())?;
    let bounds=monitor.as_ref().map(|m| {
        let area=m.work_area();
        let origin=area.position.to_logical::<f64>(m.scale_factor());
        let size=area.size.to_logical::<f64>(m.scale_factor());
        (origin.x,origin.y,size.width,size.height)
    }).unwrap_or((0.0,0.0,1440.0,900.0));
    let w=width.clamp(320.0,(bounds.2-24.0).max(320.0));
    let h=height.clamp(68.0,220.0);
    let position=window.outer_position().map_err(|e|e.to_string())?.to_logical::<f64>(scale);
    let position=if !LAYOUT_READY.load(Ordering::SeqCst){window_preferences::get("main").unwrap_or(Point{x:position.x,y:position.y})}else{Point{x:position.x,y:position.y}};
    window.set_size(tauri::LogicalSize::new(w,h)).map_err(|e|e.to_string())?;
    window.set_position(tauri::LogicalPosition::new(
        position.x.clamp(bounds.0+12.0,(bounds.0+bounds.2-w-12.0).max(bounds.0+12.0)),
        position.y.clamp(bounds.1+12.0,(bounds.1+bounds.3-h-12.0).max(bounds.1+12.0))
    )).map_err(|e|e.to_string())?;
    if !LAYOUT_READY.swap(true,Ordering::SeqCst){window_preferences::ready();window.show().map_err(|e|e.to_string())?;}
    Ok(())
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![native_request, show_settings, close_settings, sync_overlays, quit_app, request_exit, resize_toolbar, resize_settings_content, place_recording_toolbar])
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::Moved(position)=event {
                if let Ok(scale)=window.scale_factor(){let p=position.to_logical::<f64>(scale);window_preferences::moved(window.label(),Point{x:p.x,y:p.y});}
            }
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
            window_preferences::init(app.path().app_config_dir()?.join("window-positions.json"));
            #[cfg(target_os = "macos")]
            unsafe { rr_install_quit_guard(request_native_quit); rr_install_ui_callback(request_native_settings); }
            if let Some(toolbar) = app.get_webview_window("main") {
                let saved=window_preferences::get("main");
                let monitors=toolbar.available_monitors()?;
                let monitor=saved.and_then(|p|monitors.iter().find(|m|{let o=m.position().to_logical::<f64>(m.scale_factor());let z=m.size().to_logical::<f64>(m.scale_factor());p.x>=o.x&&p.x<o.x+z.width&&p.y>=o.y&&p.y<o.y+z.height})).or_else(||monitors.iter().find(|m|m.position().x==0&&m.position().y==0)).or_else(||monitors.first());
                if let Some(m)=monitor {
                    let area=m.work_area();let o=area.position.to_logical::<f64>(m.scale_factor());let z=area.size.to_logical::<f64>(m.scale_factor());
                    let p=window_preferences::clamp(saved.unwrap_or(Point{x:o.x+(z.width-850.)/2.,y:o.y+z.height-105.}),[850.,84.],[o.x+12.,o.y+12.,z.width-24.,z.height-24.]);
                    toolbar.set_position(tauri::LogicalPosition::new(p.x,p.y))?;
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

#[cfg(test)]
mod recording_toolbar_tests {
    use super::*;

    #[test]
    fn recording_toolbar_is_placed_outside_capture_region() {
        let point = recording_toolbar_position([300.0,300.0,600.0,400.0],[420.0,64.0],[0.0,0.0,1440.0,900.0]);
        let overlaps = point[0] < 900.0 && point[0] + 420.0 > 300.0 && point[1] < 700.0 && point[1] + 64.0 > 300.0;
        assert!(!overlaps,"toolbar at {point:?} overlaps capture region");
    }
}
