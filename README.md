# 靈動歌詞 · LyricIsland

極簡 OLED 黑聲學風格的 iOS 靈動島 + 懸浮視窗即時歌詞工具（完整支援 Spotify、Apple Music 與本機音訊）。

## 核心功能

- **雙引擎歌詞顯示**
  - **懸浮歌詞（Picture-in-Picture 膠囊）**：以系統畫中畫在螢幕上方常駐顯示即時雙行歌詞與進度條，即使 Spotify 佔用頂部靈動島時，仍可直接疊加顯示在 Spotify、主畫面與任意 App 上方。
  - **靈動島 + 鎖定畫面即時動態（ActivityKit / WidgetKit）**：支援收合膠囊、長按展開與鎖定畫面互動控制（`−0.5s`、`上一首`、`播放/暫停`、`下一首`、`+0.5s`）。
- **完整 Spotify 支援**
  - **Spotify 帳號直連（PKCE OAuth）**：即時輪詢播放曲目、封面與毫秒級進度，並可從懸浮窗或鎖定畫面控制切歌／播放暫停。
  - **Spotify 分享連結秒抓詞**：免登入直接貼上 `open.spotify.com/track/...` 或 `spotify.link/...` 即可自動辨識曲名、歌手並匹配時間軸歌詞。
  - **系統媒體自動偵測（MediaRemote 動態探針）**：在支援環境（如 TrollStore）中自動讀取系統當前播放曲目與進度。
- **Apple Music / 通用伴侶模式 / 本機音訊**
  - 支援 Apple Music 原生時間軸自動同步、YouTube Music / KKBOX 伴侶對時，以及本機音訊與 `.lrc` 匯入。
