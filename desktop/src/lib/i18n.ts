import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'
const zh = {
  opacity:'背景',ratio:'比例',fontDown:'减小字号',fontUp:'增大字号',speedDown:'减速',speedUp:'加速',quitConfirm:'确定退出 RecordReady 吗？',
  area:'区域',video:'视频',voice:'语音',scriptNav:'口播稿',settingsNav:'设置',cameraOff:'不录制摄像头',recordingControls:'录制控制',
  captureSize:'范围',position:'位置',positionX:'选区 X 坐标',positionY:'选区 Y 坐标',applyPosition:'应用',output:'输出',cancelArea:'取消区域选择',
  saveHelp:'屏幕视频和摄像头原片分别保存到本次会话目录。',invalid_region:'选区必须位于所选显示器内，并保持输出比例。',

  currentSystem:'当前系统为{{mode}}。',
  display:'显示器',mirror:'镜像预览',previewLayout:'预览布局',small:'小窗',fill:'铺满',previewPosition:'预览位置',
  topLeft:'左上',topRight:'右上',bottomLeft:'左下',bottomRight:'右下',manual:'手动位置',dragPreview:'拖动摄像头预览可调整位置。',
  missingSelection:'所选设备已断开',inputLevel:'输入电平',audioScreenHelp:'麦克风音轨写入屏幕视频。',promptResume:'继续提词',
  display_missing:'所选显示器已断开，请重新选择。',invalid_preview:'预览设置无效。',move:'移动控制条',recordingMode:'录音模式',
  idle:'准备设备',preparing:'正在准备',ready:'准备就绪',countdown:'倒计时',starting:'正在启动',recording:'录制中',paused:'已暂停',saving:'正在保存',saved:'已保存',partial:'部分文件已保存',failed:'保存失败',
  pauseRecording:'暂停录制',resumeRecording:'继续录制',
  prepare:'授权并预览',start:'开始录制',stop:'停止录制',cancel:'取消',camera:'摄像头设置',audio:'声音设置',size:'录制区域与尺寸',script:'编辑稿件',appearance:'应用设置',results:'保存结果',quit:'退出保护',close:'关闭',
  cameraEnabled:'启用摄像头',device:'设备',defaultDevice:'系统默认设备',nativeRequired:'请打开 RecordReady 桌面应用使用真实采集。浏览器仅供查看界面。',
  microphone:'麦克风录音',silent:'静音录制',audioHelp:'摄像头开启时，同源麦克风音轨写入两份视频。',silentHelp:'静音录制的视频不含音轨。',
  portrait:'竖屏 · 9:16',landscape:'横屏 · 16:9',other:'其他比例',custom:'自定义',width:'宽（像素）',height:'高（像素）',apply:'应用尺寸',invalid_size:'每边请输入 240–3840 的偶数整数，当前有效尺寸保持不变。',
  font:'字号',speed:'速度',slow:'慢',normal:'适中',fast:'快',promptEdit:'重置并编辑',promptStart:'开始提词',promptPause:'暂停提词',reset:'重置',scriptTitle:'稿件标题',body:'正文',done:'完成编辑',chars:'{{count}} 字',
  theme:'外观',system:'跟随系统',light:'浅色',dark:'深色',language:'语言',autoSaved:'设置自动保存',saveLocation:'保存位置',choose:'选择目录',openFolder:'打开文件夹',again:'再录一条',
  locked:'录制会话进行中，此设置已锁定。',screen_permission:'请在系统设置中允许 RecordReady 屏幕录制权限，然后重新打开应用。',camera_permission:'请允许摄像头访问后重试。',microphone_permission:'请允许麦克风访问后重试。',
  session_busy:'录制会话尚未结束，请先停止并等待保存完成。',not_ready:'请先选择录制区域。',device_missing:'找不到所需设备，请连接后重试。',device_unavailable:'设备不可用，请检查是否被其他应用占用。',directory_unwritable:'目录不可写，请选择其他目录。',
  error:'操作未完成',details:'详情',screen:'屏幕视频',cameraFile:'摄像头原片',interrupted:'录制已中断',keep:'继续录制',stopSave:'停止并保存',exit:'退出 RecordReady',quitHelp:'录制中必须先停止并保存。保存中请等待结果。',
  integration:'Mac 第一阶段 · 内部验证版',capability:'输出分辨率与桌面录制区域大小分别设置。实际能力不足时会提示原因。',previewOnly:'预览布局不改变摄像头原片。',sizeApplied:'当前输出',
}
const en: Record<keyof typeof zh,string> = {
  opacity:'Background',ratio:'Ratio',fontDown:'Decrease font size',fontUp:'Increase font size',speedDown:'Slower',speedUp:'Faster',quitConfirm:'Quit RecordReady?',
  area:'Area',video:'Video',voice:'Audio',scriptNav:'Script',settingsNav:'Settings',cameraOff:'No camera',recordingControls:'Recording controls',
  captureSize:'Size',position:'Position',positionX:'Selection X position',positionY:'Selection Y position',applyPosition:'Apply',output:'Output',cancelArea:'Cancel area selection',
  saveHelp:'Screen video and camera original are saved separately in the session folder.',invalid_region:'Keep the selection inside the display and preserve the output ratio.',

  currentSystem:'System appearance: {{mode}}.',
  display:'Display',mirror:'Mirror preview',previewLayout:'Preview layout',small:'Small',fill:'Fill',previewPosition:'Preview position',
  topLeft:'Top left',topRight:'Top right',bottomLeft:'Bottom left',bottomRight:'Bottom right',manual:'Manual position',dragPreview:'Drag the camera preview to position it.',
  missingSelection:'Selected device disconnected',inputLevel:'Input level',audioScreenHelp:'Microphone audio is written to the screen video.',promptResume:'Resume prompter',
  display_missing:'The selected display is disconnected. Choose another display.',invalid_preview:'Invalid preview settings.',move:'Move toolbar',recordingMode:'Recording mode',
  idle:'Prepare devices',preparing:'Preparing',ready:'Ready',countdown:'Countdown',starting:'Starting',recording:'Recording',paused:'Paused',saving:'Saving',saved:'Saved',partial:'Some files saved',failed:'Save failed',
  pauseRecording:'Pause recording',resumeRecording:'Resume recording',
  prepare:'Enable preview',start:'Start recording',stop:'Stop recording',cancel:'Cancel',camera:'Camera settings',audio:'Audio settings',size:'Capture region and size',script:'Edit script',appearance:'App settings',results:'Saved files',quit:'Before you quit',close:'Close',
  cameraEnabled:'Enable camera',device:'Device',defaultDevice:'System default device',nativeRequired:'Open the RecordReady desktop app for real capture. This browser view is for UI review only.',
  microphone:'Microphone audio',silent:'Record without audio',audioHelp:'When the camera is enabled, the same microphone audio is written to both videos.',silentHelp:'Videos recorded without audio contain no audio track.',
  portrait:'Portrait · 9:16',landscape:'Landscape · 16:9',other:'Other ratios',custom:'Custom',width:'Width (pixels)',height:'Height (pixels)',apply:'Apply size',invalid_size:'Enter even integers from 240 to 3840. The current valid size is unchanged.',
  font:'Font size',speed:'Speed',slow:'Slow',normal:'Normal',fast:'Fast',promptEdit:'Reset to edit',promptStart:'Start prompter',promptPause:'Pause prompter',reset:'Back to start',scriptTitle:'Script title',body:'Script',done:'Done',chars:'{{count}} characters',
  theme:'Appearance',system:'System',light:'Light',dark:'Dark',language:'Language',autoSaved:'Saved automatically',saveLocation:'Save location',choose:'Choose folder',openFolder:'Open folder',again:'Record again',
  locked:'This setting is locked during the recording session.',screen_permission:'Allow RecordReady screen recording in System Settings, then reopen the app.',camera_permission:'Allow camera access and try again.',microphone_permission:'Allow microphone access and try again.',
  session_busy:'Stop recording and wait for saving to finish first.',not_ready:'Select a capture area first.',device_missing:'Connect the required device and try again.',device_unavailable:'The device is unavailable. Check whether another app is using it.',directory_unwritable:'This folder is not writable. Choose another folder.',
  error:'Action could not finish',details:'Details',screen:'Screen video',cameraFile:'Camera original',interrupted:'Recording interrupted',keep:'Keep recording',stopSave:'Stop and save',exit:'Quit RecordReady',quitHelp:'Stop and save before quitting. If saving is in progress, wait for the result.',
  integration:'Mac phase one · Internal build',capability:'Output resolution is independent of the capture region size. Unsupported capture will report an error.',previewOnly:'Preview layout does not change the camera original.',sizeApplied:'Current output',
}
void i18n.use(initReactI18next).init({resources:{'zh-CN':{translation:zh},en:{translation:en}},lng:localStorage.getItem('rr.language') ?? (navigator.language.startsWith('zh')?'zh-CN':'en'),fallbackLng:'en',interpolation:{escapeValue:false}})
export default i18n
