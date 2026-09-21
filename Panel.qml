import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.mariusfanu.octopus-agile"
  ipcTarget: "io.github.mariusfanu.octopus-agile"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    root.controller.show()
    root.refreshIfStale()
  }

  function openFromHotkey() {
    root.controller.show()
    root.refreshIfStale()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- State -------------------------------------------------------------
  property var rates: []
  property string discoveredProduct: ""
  property double nowMs: Date.now()
  property bool loading: false
  property string error: ""
  property string lastUpdated: ""
  property double lastFetchMs: 0
  property var hoveredSlot: null
  property double lastNotifiedFromMs: 0
  property double lastNotifiedAtMs: 0
  // Never more than one toast per ~slot, whatever the data says.
  readonly property int minAlertGapMs: 25 * 60 * 1000

  // In-flight bookkeeping. A rates response is only applied when it was
  // requested for the tariff that is still selected; a refresh asked for
  // while one is running is replayed once it exits.
  property string ratesTariff: ""
  property bool ratesPending: false
  property int ratesFailures: 0
  // Set once the startup chain has issued its first rates request. QML
  // fires the *Changed handlers below during construction (default "" →
  // first bound value) and again when the host injects settings; until
  // primed, refresh() → discovery owns the first fetch.
  property bool primed: false

  onRatesChanged: {
    root.hoveredSlot = null
    Qt.callLater(root.checkAlerts)
  }

  readonly property string region: Model.normalizeRegion(setting("region", "C"), "C")
  readonly property string productOverride: Model.isValidProduct(setting("product", "")) ? String(setting("product", "")) : ""
  readonly property string product: Model.normalizeProduct(productOverride !== "" ? productOverride : discoveredProduct, Model.PRODUCT_FALLBACK)
  readonly property bool showTrend: Model.isOn(setting("showTrend", true), true)
  readonly property bool notifyCheap: Model.isOn(setting("notifyCheap", false), false)
  readonly property int notifyLeadMin: Model.clampInt(setting("notifyLeadMin", 15), 15, 5, 30)
  readonly property int notifyBelow: Model.clampInt(setting("notifyBelow", 10), 10, 0, 25)

  onNotifyCheapChanged: if (notifyCheap) Qt.callLater(root.checkAlerts)

  // Tariff inputs can change from this panel, from another bar's panel via
  // shell.json, or from discovery. Refetch once primed; while discovery is
  // running its exit handler issues the request with the new values.
  onRegionChanged: {
    lastNotifiedFromMs = 0
    resetRetries()
    if (primed && !productProc.running) refreshRates()
  }
  onProductChanged: if (primed && !productProc.running) refreshRates()

  readonly property var current: Model.findCurrent(rates, nowMs)
  readonly property var next: Model.findNext(rates, nowMs)
  readonly property var wins: Model.cheapestWindows(rates, nowMs)
  readonly property var rateStats: Model.stats(rates)
  readonly property real minPrice: rateStats.min
  readonly property real maxPrice: rateStats.max

  readonly property string label: Model.pillLabel(current ? current.price : null, next ? next.price : null, showTrend, loading)
  readonly property string tooltip: {
    if (!current)
      return "Octopus Agile " + region
    var text = "Octopus Agile " + region + " · " + Model.formatPrice(current.price)
      + " (" + timeOf(current.fromMs) + "–" + timeOf(current.toMs) + ")"
    if (next) {
      var arrow = showTrend ? Model.trendArrow(Model.priceTrend(current.price, next.price)) : ""
      text += " · next " + Model.formatPrice(next.price) + " @ " + timeOf(next.fromMs)
      if (arrow) text += " " + arrow
    }
    return text
  }

  function timeOf(ms) {
    if (ms === undefined || ms === null) return "--:--"
    return Qt.formatDateTime(new Date(ms), "HH:mm")
  }

  function dateOf(ms) {
    if (ms === undefined || ms === null) return ""
    return Qt.formatDateTime(new Date(ms), "ddd d MMM")
  }

  function priceColor(p) {
    return Model.colorForPrice(p)
  }

  function barH(p) {
    return Model.barHeight(p, minPrice, maxPrice)
  }

  function windowLabel(w) {
    if (!w) return "—"
    return timeOf(w.startMs) + "–" + timeOf(w.endMs)
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setRegion(code) {
    var nextRegion = Model.normalizeRegion(code, region)
    if (nextRegion === region) return
    persistSettings({ region: nextRegion })
  }

  function setShowTrend(on) {
    persistSettings({ showTrend: on === true })
  }

  function setNotifyCheap(on) {
    persistSettings({ notifyCheap: on === true })
  }

  function checkAlerts() {
    if (!notifyCheap || rates.length === 0) return
    var slot = Model.nextNotifiableSlot(rates, nowMs, notifyLeadMin * 60 * 1000, notifyBelow)
    if (!slot || slot.fromMs === lastNotifiedFromMs) return
    if (nowMs - lastNotifiedAtMs < minAlertGapMs) return
    sendAlert(slot)
  }

  function sendAlert(slot) {
    if (notifyProc.running) return
    var when = timeOf(slot.fromMs)
    var price = Model.formatPrice(slot.price)
    var nowP = current ? Model.formatPrice(current.price) : "—"
    var plunge = slot.price < 0
    var headline = plunge ? ("Agile plunge at " + when) : ("Cheap Agile at " + when)
    var body = price + "/kWh for 30 min · now " + nowP
    lastNotifiedFromMs = slot.fromMs
    lastNotifiedAtMs = nowMs
    notifyProc.command = [
      "omarchy-notification-send",
      "-g", "",
      "-u", plunge ? "normal" : "low",
      "--app-name", "Octopus Agile",
      headline,
      body,
      "--exec", "omarchy-shell", "io.github.mariusfanu.octopus-agile", "toggle"
    ]
    notifyProc.running = true
  }

  // Cap both Octopus responses in the producer so StdioCollector cannot grow
  // unbounded. Since curl 8.4.0 --max-filesize also aborts transfers whose
  // size is unknown up front (chunked / no Content-Length) the moment they
  // cross the limit, exiting 63; the byte check in onExited is a backstop.
  // curl is invoked directly (no shell) with the URL after "--".
  readonly property int responseCap: 131072

  function curlCommand(url, maxTime) {
    return ["curl", "-fsS",
      "--proto", "=https", "--tlsv1.2",
      "--max-time", String(maxTime),
      "--max-filesize", String(root.responseCap),
      "--", url]
  }

  function bodyBytes(collector) {
    return collector.data ? collector.data.byteLength : 0
  }

  // A response is only trusted when the process exited normally (not
  // killed) with status 0 and the body is non-empty and within the cap.
  function cleanBody(collector, code, status) {
    if (status !== 0 || code !== 0) return null
    var n = root.bodyBytes(collector)
    if (n === 0 || n > root.responseCap) return null
    var raw = String(collector.text || "").trim()
    return raw !== "" ? raw : null
  }

  function resetRetries() {
    ratesFailures = 0
    retryTimer.stop()
  }

  // Failures back off 15s → 30s → 60s → 2m → 4m, then stop and leave it
  // to the 5-minute refresh timer, so a dead endpoint (or offline machine)
  // is not polled every 15s indefinitely.
  function ratesFailed(message) {
    if (root.rates.length === 0) {
      root.error = message
      root.loading = false
    }
    root.ratesFailures++
    if (root.ratesFailures > 5) return
    retryTimer.interval = 15000 * Math.pow(2, root.ratesFailures - 1)
    retryTimer.restart()
  }

  // ---- Fetch -------------------------------------------------------------
  // User/IPC-initiated: fresh retry budget, then fetch.
  function refresh() {
    resetRetries()
    fetchOrRefresh()
  }

  // Discover the product first if that has not succeeded yet, otherwise go
  // straight to rates. Used by timers too so an offline start still ends up
  // on the latest product.
  function fetchOrRefresh() {
    nowMs = Date.now()
    if (productOverride === "" && discoveredProduct === "") {
      fetchProducts()
    } else {
      refreshRates()
    }
  }

  // Opening the popup should not cost an API call when data is fresh.
  function refreshIfStale() {
    nowMs = Date.now()
    if (rates.length === 0 || nowMs - lastFetchMs > 60 * 1000) refresh()
  }

  function fetchProducts() {
    if (productProc.running) return
    loading = rates.length === 0
    productProc.command = root.curlCommand(
      "https://api.octopus.energy/v1/products/?is_variable=true&page_size=100", 10)
    productProc.running = true
  }

  function refreshRates() {
    primed = true
    if (ratesProc.running) {
      ratesPending = true
      return
    }
    nowMs = Date.now()
    loading = rates.length === 0
    error = ""
    var from = new Date(nowMs - 12 * 3600 * 1000).toISOString()
    var to = new Date(nowMs + 36 * 3600 * 1000).toISOString()
    var tariff = Model.tariffCode(product, region)
    // product and tariff are validated (Model.PRODUCT_RE / REGIONS), so
    // encodeURIComponent is a no-op here; it stays as a second guard.
    var url = "https://api.octopus.energy/v1/products/" + encodeURIComponent(product)
      + "/electricity-tariffs/" + encodeURIComponent(tariff) + "/standard-unit-rates/"
      + "?period_from=" + encodeURIComponent(from)
      + "&period_to=" + encodeURIComponent(to)
      + "&page_size=100&ordering=valid_from"
    ratesTariff = tariff
    ratesProc.command = root.curlCommand(url, 12)
    ratesProc.running = true
  }

  function openDashboard() {
    if (root.bar) root.bar.run("xdg-open https://octopus.energy/dashboard")
  }

  Process {
    id: productProc
    stdout: StdioCollector {
      id: productOut
      waitForEnd: true
    }
    onExited: function(code, status) {
      var before = root.product
      var raw = root.cleanBody(productOut, code, status)
      if (raw !== null) {
        var latest = Model.parseLatestAgileProduct(raw)
        if (latest !== "") root.discoveredProduct = latest
      }
      // Once primed, a changed product already refetched via onProductChanged.
      if (!root.primed || root.product === before) root.refreshRates()
    }
  }

  Process {
    id: notifyProc
  }

  Process {
    id: ratesProc
    stdout: StdioCollector {
      id: ratesOut
      waitForEnd: true
    }
    onExited: function(code, status) {
      // Region/product changed mid-flight: this body is for the wrong
      // tariff. Drop it and fetch the right one.
      var stale = root.ratesTariff !== Model.tariffCode(root.product, root.region)
      var failed = status !== 0 || code !== 0
      // Replay a queued refresh only when this result cannot serve it.
      if (stale || (root.ratesPending && failed)) Qt.callLater(root.refreshRates)
      root.ratesPending = false
      if (stale) return

      if (failed) {
        // curl -f exits 22 on HTTP >= 400. A 404 for a product we chose
        // ourselves means discovery picked a tariff that does not exist.
        // Pin the known-good fallback for this session rather than
        // re-discovering, which would just pick the same code again.
        if (code === 22 && root.productOverride === "" && root.discoveredProduct !== ""
            && root.discoveredProduct !== Model.PRODUCT_FALLBACK)
          root.discoveredProduct = Model.PRODUCT_FALLBACK
        root.ratesFailed("Fetch failed (code " + code + ")")
        return
      }
      var n = root.bodyBytes(ratesOut)
      if (n > root.responseCap) {
        root.ratesFailed("Response too large")
        return
      }
      var raw = root.cleanBody(ratesOut, code, status)
      if (raw === null) {
        root.ratesFailed("No data — check connection")
        return
      }
      var parsed = Model.parseRates(raw)
      if (parsed.length === 0) {
        root.ratesFailed("No Agile slots returned")
        return
      }
      root.rates = parsed
      root.error = ""
      root.loading = false
      root.resetRetries()
      root.lastFetchMs = Date.now()
      root.lastUpdated = Qt.formatDateTime(new Date(), "HH:mm:ss")
    }
  }

  Timer {
    id: retryTimer
    interval: 15000
    repeat: false
    onTriggered: root.fetchOrRefresh()
  }

  // Periodic refresh only; the first fetch is driven from onCompleted via
  // product discovery so startup issues a single rates request.
  Timer {
    id: refreshTimer
    interval: 5 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.fetchOrRefresh()
  }

  Timer {
    id: clockTimer
    interval: 30000
    running: true
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      root.checkAlerts()
    }
  }

  Component.onCompleted: Qt.callLater(root.refresh)

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(col.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: regionDropdown.popupOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: col
          width: parent.width
          spacing: Style.space(14)

          // ---- Hero ------------------------------------------------------
          Item {
            width: parent.width
            height: Math.max(heroLeft.height, heroRight.height)

            Row {
              id: heroLeft
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(14)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                color: root.current ? root.priceColor(root.current.price) : (root.bar ? root.bar.foreground : "#fff")
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: 44
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Row {
                  spacing: Style.space(4)
                  Text {
                    textFormat: Text.PlainText
                    text: root.current ? Model.formatPrice(root.current.price) : (root.loading ? "…" : "—")
                    color: root.bar ? root.bar.foreground : "#fff"
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: 40
                    font.bold: true
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: root.current !== null
                    text: root.current && root.current.price < 0 ? "FREE" : ""
                    color: "#22d3ee"
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    anchors.top: parent.top
                    anchors.topMargin: Style.space(8)
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.current ? (root.timeOf(root.current.fromMs) + "–" + root.timeOf(root.current.toMs) + " · " + root.dateOf(root.current.fromMs)) : ""
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "#aaa"
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }
              }
            }

            Column {
              id: heroRight
              anchors.right: parent.right
              anchors.rightMargin: Style.space(20)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: "REGION " + root.region
                color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "#aaa"
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                text: Model.regionLabel(root.region)
                color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "#aaa"
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              Column {
                spacing: Style.space(2)
                Text {
                  textFormat: Text.PlainText
                  text: "NEXT"
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "#888"
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.next ? (Model.formatPrice(root.next.price) + " @ " + root.timeOf(root.next.fromMs)) : "—"
                  color: root.next ? root.priceColor(root.next.price) : (root.bar ? root.bar.foreground : "#fff")
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
              }
            }
          }

          Text {
            visible: root.error !== "" && root.rates.length === 0
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: root.error + " · middle-click pill to retry"
            color: "#f87171"
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- Stats ------------------------------------------------------
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(36)

            Column {
              spacing: Style.space(4)
              Text { textFormat: Text.PlainText; text: "MIN"; color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "#888"; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
              Text { textFormat: Text.PlainText; text: root.rates.length > 0 ? Model.formatPrice(root.minPrice) : "—"; color: root.priceColor(root.minPrice); font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.title; font.bold: true }
            }
            Column {
              spacing: Style.space(4)
              Text { textFormat: Text.PlainText; text: "AVG"; color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "#888"; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
              Text { textFormat: Text.PlainText; text: root.rates.length > 0 ? Model.formatPrice(root.rateStats.avg) : "—"; color: root.bar ? root.bar.foreground : "#fff"; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.title; font.bold: true }
            }
            Column {
              spacing: Style.space(4)
              Text { textFormat: Text.PlainText; text: "MAX"; color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "#888"; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
              Text { textFormat: Text.PlainText; text: root.rates.length > 0 ? Model.formatPrice(root.maxPrice) : "—"; color: root.priceColor(root.maxPrice); font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.title; font.bold: true }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.bar ? root.bar.foreground : "#fff"
          }

          // ---- Cheapest windows -------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "CHEAPEST WINDOWS FROM NOW"
              foreground: root.bar ? root.bar.foreground : "#fff"
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }

            Repeater {
              model: [
                { hours: "1H", win: root.wins.h1 },
                { hours: "2H", win: root.wins.h2 },
                { hours: "3H", win: root.wins.h3 }
              ]

              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(10)
                  height: Style.space(10)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: modelData.win ? root.priceColor(modelData.win.avg) : "transparent"
                  border.width: modelData.win ? 0 : 1
                  border.color: root.bar ? Qt.darker(root.bar.foreground, 2) : "#555"
                }

                Text {
                  textFormat: Text.PlainText
                  width: Style.space(28)
                  text: modelData.hours
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "#aaa"
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: modelData.win ? root.windowLabel(modelData.win) : "—"
                  color: root.bar ? root.bar.foreground : "#fff"
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                Item { width: Style.space(4); height: 1 }

                Text {
                  textFormat: Text.PlainText
                  text: modelData.win ? ("avg " + Model.formatPrice(modelData.win.avg)) : ""
                  color: modelData.win ? root.priceColor(modelData.win.avg) : (root.bar ? root.bar.foreground : "#fff")
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.bar ? root.bar.foreground : "#fff"
          }

          // ---- Day chart ---------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "ALL SLOTS (30 MIN)"
              foreground: root.bar ? root.bar.foreground : "#fff"
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }

            Text {
              visible: root.rates.length === 0
              textFormat: Text.PlainText
              text: root.loading ? "Fetching Agile prices…" : "No data yet"
              color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "#888"
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }

            // Hover readout — hovered slot, otherwise the current one.
            Text {
              visible: root.rates.length > 0
              width: parent.width
              horizontalAlignment: Text.AlignRight
              textFormat: Text.PlainText
              text: root.hoveredSlot
                ? (root.timeOf(root.hoveredSlot.fromMs) + "–" + root.timeOf(root.hoveredSlot.toMs) + "  ·  " + Model.formatPrice(root.hoveredSlot.price))
                : (root.current ? ("now  " + root.timeOf(root.current.fromMs) + "–" + root.timeOf(root.current.toMs) + "  ·  " + Model.formatPrice(root.current.price)) : "")
              color: root.hoveredSlot ? root.priceColor(root.hoveredSlot.price) : (root.bar ? Qt.darker(root.bar.foreground, 1.4) : "#aaa")
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Item {
              visible: root.rates.length > 0
              width: parent.width
              height: 110

              // Y axis: gridlines + price labels at max / mid / min.
              Repeater {
                model: root.rates.length > 0 ? [root.maxPrice, (root.minPrice + root.maxPrice) / 2, root.minPrice] : []

                Item {
                  required property var modelData
                  property real lineY: 92 - 88 * root.barH(modelData)
                  width: parent.width
                  height: 16
                  y: lineY - 8

                  Text {
                    x: 0
                    width: 44
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignRight
                    textFormat: Text.PlainText
                    text: Model.formatPrice(modelData)
                    color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "#888"
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: 10
                  }

                  Rectangle {
                    x: 48
                    width: parent.width - 48 - 16
                    height: 1
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.bar ? root.bar.foreground : "#fff"
                    opacity: 0.15
                  }
                }
              }

              Row {
                id: chartRow
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 18
                anchors.left: parent.left
                anchors.leftMargin: Style.space(48)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(16)
                spacing: Math.max(1, Math.min(3, (width - root.rates.length * 4) / Math.max(1, root.rates.length)))

                Repeater {
                  model: root.rates

                  Rectangle {
                    required property var modelData
                    required property int index
                    width: Math.max(3, (chartRow.width - (root.rates.length - 1) * chartRow.spacing) / Math.max(1, root.rates.length))
                    height: Math.max(6, 88 * root.barH(modelData.price))
                    anchors.bottom: parent.bottom
                    radius: 2
                    color: root.priceColor(modelData.price)
                    opacity: (root.current && modelData.fromMs === root.current.fromMs) || (root.hoveredSlot && modelData.fromMs === root.hoveredSlot.fromMs) ? 1.0 : 0.75
                    border.width: root.current && modelData.fromMs === root.current.fromMs ? 2 : 0
                    border.color: root.bar ? root.bar.foreground : "#fff"

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onEntered: root.hoveredSlot = modelData
                      onExited: {
                        if (root.hoveredSlot && root.hoveredSlot.fromMs === modelData.fromMs) root.hoveredSlot = null
                      }
                    }
                  }
                }
              }

              // Time ticks every ~4h
              Repeater {
                model: root.rates.length > 0 ? Math.ceil(root.rates.length / 8) : 0
                Text {
                  required property int index
                  property var slot: root.rates[index * 8]
                  x: Style.space(48) + index * 8 * ((chartRow.width - (root.rates.length - 1) * chartRow.spacing) / Math.max(1, root.rates.length) + chartRow.spacing)
                  y: 94
                  width: 40
                  textFormat: Text.PlainText
                  text: slot ? root.timeOf(slot.fromMs) : ""
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.6) : "#777"
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: 10
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.bar ? root.bar.foreground : "#fff"
          }

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "PILL"
              foreground: root.bar ? root.bar.foreground : "#fff"
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }

            Toggle {
              width: parent.width
              label: "Next-slot arrow"
              description: "Show ↑ or ↓ when the next half-hour is a different price"
              checked: root.showTrend
              foreground: root.bar ? root.bar.foreground : "#fff"
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.setShowTrend(!root.showTrend)
            }

            Toggle {
              width: parent.width
              label: "Cheap window alerts"
              description: "Off by default. Notify before a slot below " + root.notifyBelow + "p, " + root.notifyLeadMin + " min ahead"
              checked: root.notifyCheap
              foreground: root.bar ? root.bar.foreground : "#fff"
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.setNotifyCheap(!root.notifyCheap)
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.bar ? root.bar.foreground : "#fff"
          }

          // ---- Footer: region + actions ------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(10)

            Dropdown {
              id: regionDropdown
              width: Style.space(220)
              label: "Region"
              value: root.region
              options: Model.REGIONS
              foreground: root.bar ? root.bar.foreground : "#fff"
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onChanged: function(v) { root.setRegion(v) }
            }

            Item { width: Style.space(4); height: 1 }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑓"
              tooltipText: "Refresh prices"
              foreground: root.bar ? root.bar.foreground : "#fff"
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.refreshRates()
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰖟"
              tooltipText: "Open Octopus dashboard"
              foreground: root.bar ? root.bar.foreground : "#fff"
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.openDashboard()
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.lastUpdated !== ""
            width: parent.width
            horizontalAlignment: Text.AlignRight
            text: "Updated " + root.lastUpdated + " · " + root.product + "-" + root.region
            color: root.bar ? Qt.darker(root.bar.foreground, 1.8) : "#666"
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: 10
          }
        }
      }
    }
  }
}
