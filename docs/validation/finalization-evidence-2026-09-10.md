# 2026-09-10 定案檢查證據摘錄

基準：`81c5ceb006e6bad68ca6921a2e813c5788d3dd76`。未改正式 Sources。

## 現有套件

命令：`SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 ./scripts/run-checks.sh`  
exit code：0。

```text
Ran 22 tests in 0.002s
Ran 3 tests in 0.007s
72 passed, 0 failed
Executed 250 tests, with 0 failures (0 unexpected) in 53.750 (53.790) seconds
SKIP App bundle build: SKIP_APP_BUNDLE=1
✅ 全部驗證通過！
```

10 種 pipeline 情境亦全部通過。完整紀錄：`/tmp/record-final-review-20260910.log`。

## 診斷案例

當時將 `FinalizationReviewProbeTests.swift` 暫放入 `Tests/RecordToTextCoreTests/`，執行：

```sh
swift test --disable-sandbox --filter FinalizationReviewProbeTests
```

5 個測試正常編譯執行，5 個 assertions 失敗，exit code 1。檢查後曾移回 docs；使用者授權實作後已納入正式測試 target，這份保留修正前的證據。

```text
testAmbiguousSuffixMustNotChooseFirstPerson
XCTAssertEqual failed: ("王小明：我補充一下。") is not equal to ("小明：我補充一下。")

testGapWarningMustSurvivePersistenceRoundTrip
XCTAssertTrue failed

testLocalJobMustNotFailWhileCredentialLoadIsPending
XCTAssertNotEqual failed: ("failed") is equal to ("failed")
Error Domain=NSCocoaErrorDomain Code=512 "無法儲存檔案。"

testOrdinarySentenceMustNotBecomeSpeakerName
XCTAssertEqual failed: ("負責這：我是負責這個專案的窗口。") is not equal to ("講者 1：我是負責這個專案的窗口。")

testRepeatedGenericLabelMustNotOverrideExplicitNewIntroduction
XCTAssertFalse failed

Executed 5 tests, with 5 failures (0 unexpected) in 0.138 (0.140) seconds
```

完整紀錄：`/tmp/record-final-probes-20260910.log`。

案例使用合成文字、隔離暫存目錄及受控 credential store。沒有讀取真實金鑰、轉錄使用者音檔或呼叫雲端服務。F-03 證據是持久化後狀態資訊丟失，不是 TXT 檔案消失。
