# IPCF 同工助手

IPCF 的同工工具：服事表、同工帳號與權限管理，以及 LINE 服事提醒。Flutter Web 製作的 PWA，可以加到手機主畫面當 App 用。

網站、資料庫和帳號都在教會自己的 **Firebase 專案**與 **Cloudflare 帳號**裡。程式改自 Hans Lee 的開源專案 [church-staff-pwa](https://github.com/hansli112/church-staff-pwa)（見最下方「來源與授權」）。

| | 網址 |
|---|---|
| 正式網站 | https://ipcf-church-staff.pages.dev |
| 預覽網站（`dev` 分支） | https://dev.ipcf-church-staff.pages.dev |
| LINE 服事提醒（官方帳號 ID） | `@167hbeza` |

## IPCF 版的修改

**服事表頁面改版**（`lib/features/roster/`）

- 右上角「卡片｜表格」切換。表格模式手機一頁看得完、不用左右滑：
  - 每週分「台」「華」兩行：講員各自對應；其他服事都是華語同工，放「華」行；寫「台語」的佔位放「台」行。
  - 聯合崇拜只有一場，合併成一行（「合」）。
  - 整段期間沒人排的服事項目不顯示。
- 「只看我的」：只列出排到自己的日子。
- 顏色固定各有意思，不要混用：**綠色＝我的服事**、**黃色＝聯合崇拜**、紫色＝聖餐、灰色＝台語堂負責。
- 卡片預設展開最近兩週；收起來也顯示講員和敬拜主領。
- 規則集中在 `lib/features/roster/domain/roster_view_model.dart`，測試在 `test/roster_view_model_test.dart`。

**保留教會 Logo**：網站最初是用安裝精靈裝的，Logo 是精靈產生的、不在原始碼裡。部署時若設了 `CHURCH_BRANDING_URL`，GitHub Actions 會先把線上網站的五張圖示抓回來（`.github/workflows/deploy-flutter-pwa.yml` 的「Keep the current church logo」）。

**LINE 服事提醒**（`ipcf/line-reminder/worker.js`）：見下方。

## 怎麼改版、怎麼上線

部署全部走 GitHub Actions（`Deploy Flutter PWA`），每次都會先跑 `flutter analyze` 和全部測試，沒過就不會部署。

1. 改好的程式推到 **`dev`** 分支 → 自動部署到**預覽網站**，正式網站不受影響。
2. 在預覽網站確認沒問題。
3. 把 `dev` 合併（fast-forward）到 **`main`** → 自動部署到**正式網站**。

> ⚠️ **預覽網站和正式網站用的是同一個資料庫。** 在預覽網站「看」沒問題，但在上面改服事表、加帳號，改的就是真正的資料。

> ⚠️ **不要用原專案的安裝精靈「更新」網站。** 那會用原版重新建置，把 IPCF 的修改蓋掉。「我的」頁面出現「有新版本可以更新」時，指的是原專案出了新版：把它合併進這個 repo（GitHub 上的「Sync fork」，有衝突要手動處理），推到 `dev` 測過再上 `main`。

**出問題時退回**：Cloudflare → Workers & Pages → `ipcf-church-staff` → Deployments，選前一個正常的版本 → Rollback。

### GitHub Actions 需要的設定

Settings → Secrets and variables → Actions。值不寫在這裡；需要時看現在的網站或問負責的同工。

| 類型 | 名稱 | 說明 |
|---|---|---|
| Variable | `CLOUDFLARE_PAGES_PROJECT` | Cloudflare Pages 專案名稱 |
| Variable | `CHURCH_CONFIG_JSON` | 網站設定（名稱、時區、功能開關）；聚會清單之後在 App 的「聚會設定」改 |
| Variable | `CHURCH_BRANDING_URL` | 正式網站網址，用來保留 Logo |
| Variable | `FIREBASE_API_KEY`、`FIREBASE_AUTH_DOMAIN`、`FIREBASE_PROJECT_ID`、`FIREBASE_STORAGE_BUCKET`、`FIREBASE_MESSAGING_SENDER_ID`、`FIREBASE_APP_ID` | Firebase 網頁設定（本來就公開在網站上） |
| Secret | `CLOUDFLARE_ACCOUNT_ID` | 網站所在的 Cloudflare 帳號 |
| Secret | `CLOUDFLARE_API_TOKEN` | 只需「Cloudflare Pages：Edit」權限 |

## LINE 服事提醒

每週三、週六晚上 8 點（洛杉磯時間），私訊接下來 4 天內有服事的同工。只發給有服事的人，所以一個月大約幾十則，在 LINE 台灣方案的免費額度（每月 200 則）以內。

- **同工怎麼用**：加官方帳號好友，傳「綁定 名字」（名字要跟服事表上的寫法一樣）。也可以傳「我的服事」「解除綁定」。這些都是回覆訊息，不算額度。
- **跑在哪裡**：Cloudflare Worker `ipcf-line-reminder`（跟網站同一個 Cloudflare 帳號），程式就是 `ipcf/line-reminder/worker.js`。這份檔案**不會**被 GitHub Actions 自動部署；改了之後要到 Cloudflare 後台貼上新的程式。
- **怎麼讀服事表**：用 App 裡一個一般同工帳號「LINE 小幫手」登入讀資料，受資料庫規則限制，只看得到同工本來就看得到的東西。**不要刪掉這個同工帳號**，否則提醒會停止。
- **綁定資料**：存在 Worker 的 KV（`ipcf-line-bindings`）。
- **設定**（Worker → Settings）：
  - Variables：`FIREBASE_PROJECT_ID`、`FIREBASE_API_KEY`、`SITE_URL`、`TIME_ZONE`
  - Secrets：`LINE_CHANNEL_SECRET`、`LINE_CHANNEL_ACCESS_TOKEN`、`BOT_EMAIL`、`BOT_PASSWORD`、`ADMIN_KEY`
  - 排程（UTC）：`0 3 * * THU,SUN` 和 `0 4 * * THU,SUN`。兩條是為了夏令／冬令時間，程式只會在當地晚上 8 點那次發送。
- **檢查**：瀏覽器開 `https://ipcf-line-reminder.<子網域>.workers.dev/admin/preview?key=<ADMIN_KEY>`，可以看到這次會發給誰（不會真的發送）。
- **用量**：LINE 官方帳號後台 →「分析」可以看這個月用了幾則。
- **換班／代班**：同工傳「換班」（或按選單），選自己的服事 → 代班或互換 → 小幫手從同工名單推薦人選（當天沒有不能兼任的服事、前後一週沒有同一項、比例不是 0%，今年天數少的在前）→ 已私下講好就送出，或請小幫手私訊對方按同意／婉拒（婉拒會把新的推薦名單傳回給申請人）。申請存在 KV（`swapreq:<id>`），管理員在 App「我的 → 換班申請」核准：App 用管理員權限改服事表，再呼叫 Worker 的 `/api/swaps/<id>` 用 LINE 通知雙方。App 用 `LINE_WORKER_URL`（`lib/features/roster/data/swap_request_api.dart`）找到 Worker；Worker 只接受 `role` 是 `admin` 的 Firebase 登入憑證。
- **測試**：`node --test ipcf/line-reminder/`（CI 也會跑）。

## 權限與資料安全

`role` 表示身分；`admin`（管理員）有全部權限，其他人的編輯權限由 `groups` 控制，服事表另外受 `zones`／`zoneTypes`（牧區）限制。

| 動作 | 管理員 | 服事表編輯（roster-editors） | 行事曆編輯（calendar-editors） |
|---|---|---|---|
| 編輯服事表 | 全部聚會 | 自己的牧區 | 不行 |
| 讀取同工完整名單 | 可以 | 可以 | 不行 |
| 帳號、角色、群組與範本管理 | 可以 | 不行 | 不行 |

- 真正擋資料的是 `firestore.rules`，畫面上隱藏按鈕不算授權。
- 在 App 刪除同工時，登入帳號會一起刪掉（網站設定了 `ACCOUNT_ADMIN_KEY`）。
- **隱私**：能讀同工名單的人，也看得到名單文件裡的 Email 等欄位。收集資料以必要為限；備份、刪除與帳號停用由教會負責。
- Firebase 網頁 API key 本來就看得到，不是秘密；真正的秘密（Cloudflare token、LINE token、小幫手密碼等）只放在 GitHub Secrets／Cloudflare Secrets，**不可以寫進程式碼或這個 repo**。這個 repo 是公開的，也**不要放同工名單或服事表資料**。

## 開發與驗證

```bash
flutter pub get
flutter analyze
flutter test
dart format lib test

# 不需要網路的 Node 測試
npm test --prefix functions-tests
npm test --prefix web-tests

# Firestore 規則測試（需要 Java 與 Firebase emulator）
npm ci --prefix firestore-tests
npm test --prefix firestore-tests
```

GitHub Actions 每次部署前都會跑上面這些檢查。本機沒有 Flutter 也沒關係：推到 `dev`，看 Actions 的結果即可。

原始碼主要位置：

- `lib/features/<功能>/{domain,data,presentation}/`：各功能的資料模型、資料存取、畫面。服事表在 `lib/features/roster/`。
- `lib/core/`：共用設定、型別與 UI 工具。
- `functions/`、`worker/`：網站後端（Cloudflare Pages Functions），例如同工帳號管理。
- `firestore.rules`、`firestore-tests/`：資料庫權限規則與測試。
- `web/`、`web-tests/`：PWA 資源與快取測試。
- `ipcf/line-reminder/`：LINE 服事提醒（另外部署到 Cloudflare Worker）。
- `docs/`：原專案的部署指南與技術文件，要開選用功能（行事曆、照片辨識、推播等）時參考 `docs/deployment.md`。

## 來源與授權

本專案改自 Hans Lee 的 [hansli112/church-staff-pwa](https://github.com/hansli112/church-staff-pwa)，依 [MIT License](LICENSE) 使用；`LICENSE` 裡的原著作權聲明必須保留。IPCF 的修改同樣以 MIT 授權。

MIT 只適用於本專案的原創程式碼與中性圖示，**不包含** Flutter、套件、字型、聖經譯本等第三方內容（見 [第三方授權與素材](docs/third-party-notices.md)）；教會名稱、Logo 與資料由 IPCF 自行負責。
