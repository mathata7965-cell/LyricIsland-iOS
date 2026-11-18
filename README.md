# 靈動歌詞 · LyricIsland

極簡 OLED 黑聲學風格的 iOS 靈動島即時歌詞工具（支援 Dynamic Island 與鎖定畫面即時動態）。

## 核心功能

- **靈動島 + 鎖定畫面即時動態（ActivityKit / WidgetKit）**
  - 收合膠囊即時滾動目前歌詞與專輯縮圖
  - 長按展開完整封面、目前句與翻譯／下一句預告、60fps 原生進度軸，以及互動按鈕（`−0.5s`、`上一句`、`播放/暫停`、`下一句`、`+0.5s`）
  - 三種顯示模式：`極簡詞島`、`雙行歌詞`、`聲學儀表`
- **三路同步引擎**
  - **Apple Music 即時跟隨**：自動讀取系統正在播放的曲目、封面與時間軸並匹配同步 LRC
  - **外播伴侶模式**：搭配 Spotify / YouTube Music / KKBOX，配合背景靜音混音保活與快速時間軸對齊
  - **本機音訊與 `.lrc`**：支援匯入 `mp3 / m4a / flac / wav` 與同名 `.lrc`，讀取內嵌封面與歌詞
- **快捷指令自動化 URL Scheme**
  - `lyricisland://start`
  - `lyricisland://stop`
  - `lyricisland://sync?title=曲名&artist=歌手&autoplay=1`

## 雲端編譯 IPA（Windows）

```powershell
powershell -ExecutionPolicy Bypass -File .\Build-IPA-Cloud.ps1
```
