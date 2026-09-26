use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::PathBuf, sync::{Mutex, OnceLock, atomic::{AtomicBool, AtomicU64, Ordering}}};

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
pub struct Point { pub x: f64, pub y: f64 }
static POSITIONS: OnceLock<Mutex<BTreeMap<String, Point>>> = OnceLock::new();
static PATH: OnceLock<PathBuf> = OnceLock::new();
static READY: AtomicBool = AtomicBool::new(false);
static REVISION: AtomicU64 = AtomicU64::new(0);
static SECTION: Mutex<String> = Mutex::new(String::new());

fn parse(text: &str) -> BTreeMap<String, Point> {
    serde_json::from_str::<serde_json::Value>(text).ok().and_then(|v|v.as_object().cloned()).unwrap_or_default()
        .into_iter().filter_map(|(key,v)| serde_json::from_value::<Point>(v).ok().filter(|p|p.x.is_finite()&&p.y.is_finite()).map(|p|(key,p))).collect()
}
pub fn init(path: PathBuf) {
    let values=std::fs::read_to_string(&path).map(|s|parse(&s)).unwrap_or_default();
    let _=PATH.set(path); let _=POSITIONS.set(Mutex::new(values));
}
pub fn ready() { READY.store(true,Ordering::SeqCst); }
pub fn section(value: &str) { if let Ok(mut s)=SECTION.lock(){ *s=value.into(); } }
pub fn get(key: &str) -> Option<Point> { POSITIONS.get()?.lock().ok()?.get(key).copied() }
pub fn moved(label: &str, point: Point) {
    if !READY.load(Ordering::SeqCst)||!point.x.is_finite()||!point.y.is_finite(){return;}
    let key=match label { "main"=>"main".into(), "settings"=>{
        let Ok(s)=SECTION.lock() else{return;};
        if s.is_empty(){return;} format!("settings:{s}")
    }, _=>return };
    let Some(values)=POSITIONS.get() else{return;};
    let Ok(mut values)=values.lock() else{return;};
    if values.get(&key)==Some(&point){return;}
    values.insert(key,point);drop(values);
    let revision=REVISION.fetch_add(1,Ordering::SeqCst)+1;
    std::thread::spawn(move||{std::thread::sleep(std::time::Duration::from_millis(250));if REVISION.load(Ordering::SeqCst)==revision{flush();}});
}
pub fn flush() {
    let (Some(path),Some(values))=(PATH.get(),POSITIONS.get()) else{return;};
    // Hold the lock through rename so a delayed write cannot replace newer geometry.
    let Ok(values)=values.lock() else{return;};
    let Ok(bytes)=serde_json::to_vec(&*values) else{return;};
    if let Some(parent)=path.parent(){if std::fs::create_dir_all(parent).is_err(){return;}}
    let temp=path.with_extension("tmp");
    if std::fs::write(&temp,bytes).is_ok(){let _=std::fs::rename(temp,path);}
}
pub fn clamp(point: Point, size: [f64;2], bounds: [f64;4]) -> Point {
    Point{x:point.x.clamp(bounds[0],(bounds[0]+bounds[2]-size[0]).max(bounds[0])),y:point.y.clamp(bounds[1],(bounds[1]+bounds[3]-size[1]).max(bounds[1]))}
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn bad_entry_does_not_discard_other_windows(){
        let p=parse(r#"{"main":{"x":20,"y":40},"settings:appearance":{"x":"bad","y":0}}"#);
        assert_eq!(p.len(),1);assert_eq!(p["main"],Point{x:20.,y:40.});
    }
    #[test] fn clamp_disconnected_screen_and_oversize_window(){
        assert_eq!(clamp(Point{x:2000.,y:-500.},[320.,80.],[12.,40.,1000.,700.]),Point{x:692.,y:40.});
        assert_eq!(clamp(Point{x:-300.,y:900.},[1200.,900.],[12.,40.,1000.,700.]),Point{x:12.,y:40.});
    }
}
