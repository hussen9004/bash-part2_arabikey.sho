#!/usr/bin/env bash
set -e

PROJECT_DIR="${1:-ArabiKey}"
cd "$PROJECT_DIR"

mkdir -p \
  app/src/main/java/com/arabikey/keyboard \
  app/src/test/java/com/arabikey/keyboard

cat <<'__ARABIKEY_EOF__' > .gitignore
*.iml
.gradle/
/local.properties
/.idea/
.DS_Store
/build/
/app/build/
captures/
__ARABIKEY_EOF__

cat <<'__ARABIKEY_EOF__' > app/src/main/java/com/arabikey/keyboard/ArabiKeyService.kt
package com.arabikey.keyboard

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.inputmethodservice.InputMethodService
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.FileProvider
import androidx.core.view.inputmethod.EditorInfoCompat
import androidx.core.view.inputmethod.InputConnectionCompat
import androidx.core.view.inputmethod.InputContentInfoCompat
import java.io.File
import kotlin.math.abs

class ArabiKeyService : InputMethodService() {

    private val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
    private val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

    private lateinit var prefs: Prefs
    private var kb: KbTheme = KbTheme.SNOW
    private var root: LinearLayout? = null
    private var keysHost: LinearLayout? = null

    private var page = Page.AR
    private var lang = "ar"
    private var shiftState = 0
    private var haptic = true
    private var sound = false
    private var suggestOn = true
    private var selectedSticker: File? = null

    private var suggestionViews: List<TextView> = emptyList()
    private var suggestions: List<String> = listOf("", "", "")

    private val handler = Handler(Looper.getMainLooper())
    private var clipListener: ClipboardManager.OnPrimaryClipChangedListener? = null

    private var popup: PopupWindow? = null
    private var popupRow: LinearLayout? = null
    private var popupAlts: List<String> = emptyList()
    private var popupSelectedIdx = 0
    private var popupOriginX = 0
    private var popupItemW = 0

    private val repeatBack = object : Runnable {
        override fun run() {
            backspace()
            handler.postDelayed(this, 45)
        }
    }

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        kb = KbTheme.byName(prefs.theme)
        lang = prefs.lang
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val l = ClipboardManager.OnPrimaryClipChangedListener {
                if (prefs.clipboardEnabled) captureClip(cm)
            }
            clipListener = l
            cm.addPrimaryClipChangedListener(l)
        } catch (e: Exception) {
        }
    }

    override fun onDestroy() {
        dismissPopup()
        handler.removeCallbacksAndMessages(null)
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipListener?.let { cm.removePrimaryClipChangedListener(it) }
        } catch (e: Exception) {
        }
        super.onDestroy()
    }

    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onCreateInputView(): View {
        val r = LinearLayout(this)
        r.orientation = LinearLayout.VERTICAL
        r.layoutDirection = View.LAYOUT_DIRECTION_LTR
        root = r
        buildUi()
        return r
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        lang = prefs.lang
        val cls = info.inputType and InputType.TYPE_MASK_CLASS
        val variation = info.inputType and InputType.TYPE_MASK_VARIATION
        suggestOn = prefs.suggestEnabled
        page = if (lang == "ar") Page.AR else Page.EN

        if (cls == InputType.TYPE_CLASS_NUMBER || cls == InputType.TYPE_CLASS_PHONE || cls == InputType.TYPE_CLASS_DATETIME) {
            page = Page.SYM
            suggestOn = false
        } else if (cls == InputType.TYPE_CLASS_TEXT) {
            val latinOnly = variation == InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS ||
                variation == InputType.TYPE_TEXT_VARIATION_URI ||
                variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            if (latinOnly) {
                lang = "en"
                page = Page.EN
            }
            if (variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            ) {
                suggestOn = false
            }
        }
        shiftState = 0
        selectedSticker = null
        buildUi()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        handler.removeCallbacksAndMessages(null)
        dismissPopup()
        super.onFinishInputView(finishingInput)
    }

    override fun onUpdateSelection(
        oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int,
        candidatesStart: Int, candidatesEnd: Int,
    ) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        updateSuggestions()
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun keyHeightDp(): Int {
        val base = when (prefs.keyHeight) {
            0 -> 48
            1 -> 56
            3 -> 72
            else -> 64
        }
        val landscape = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        return if (landscape) (base * 0.74f).toInt() else base
    }

    private fun charFontSp(): Float = when (prefs.fontSize) {
        0 -> 21f
        2 -> 27f
        else -> 24f
    }

    private fun rowHeight(): Int = dp(keyHeightDp()) + dp(5)

    private fun buildUi() {
        val r = root ?: return
        dismissPopup()
        kb = KbTheme.byName(prefs.theme)
        haptic = prefs.haptic
        sound = prefs.sound
        r.removeAllViews()
        r.setBackgroundColor(kb.bg)
        r.addView(buildBar(), LinearLayout.LayoutParams(MATCH, dp(46)))
        val host = LinearLayout(this)
        host.orientation = LinearLayout.VERTICAL
        keysHost = host
        r.addView(host, LinearLayout.LayoutParams(MATCH, WRAP))
        applyWindowColors()
        renderPage()
    }

    private fun applyWindowColors() {
        try {
            val w = window?.window ?: return
            w.navigationBarColor = kb.bg
            if (Build.VERSION.SDK_INT >= 26) {
                val flags = w.decorView.systemUiVisibility
                w.decorView.systemUiVisibility =
                    if (kb.isLight) flags or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
                    else flags and View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR.inv()
            }
        } catch (e: Exception) {
        }
    }

    private fun mainPage(): Page = if (lang == "ar") Page.AR else Page.EN

    private fun buildBar(): View {
        val bar = LinearLayout(this)
        bar.orientation = LinearLayout.HORIZONTAL
        bar.gravity = Gravity.CENTER_VERTICAL
        bar.setBackgroundColor(kb.bar)
        bar.setPadding(dp(4), dp(3), dp(4), dp(3))

        val gearBtn = iconButton("⚙️", 34) {
            page = if (page == Page.SETTINGS) mainPage() else Page.SETTINGS
            shiftState = 0
            renderPage()
        }
        gearBtn.setOnLongClickListener {
            feedback(it)
            openSettings()
            true
        }
        bar.addView(gearBtn)

        bar.addView(iconButton("📋", 34) {
            page = if (page == Page.CLIP) mainPage() else Page.CLIP
            shiftState = 0
            renderPage()
        })

        bar.addView(iconButton("🖼️", 34) {
            page = if (page == Page.STICKER) mainPage() else Page.STICKER
            shiftState = 0
            renderPage()
        })

        val views = ArrayList<TextView>()
        for (i in 0 until 3) {
            val tv = TextView(this)
            tv.gravity = Gravity.CENTER
            tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            tv.setTextColor(kb.text)
            tv.maxLines = 1
            tv.ellipsize = TextUtils.TruncateAt.END
            tv.setOnClickListener {
                feedback(it)
                applySuggestion(i)
            }
            bar.addView(tv, LinearLayout.LayoutParams(0, MATCH, 1f))
            views.add(tv)
            if (i < 2) {
                val d = View(this)
                d.setBackgroundColor(kb.divider)
                bar.addView(d, LinearLayout.LayoutParams(dp(1), dp(20)))
            }
        }
        suggestionViews = views

        if (prefs.dedicatedSend) {
            val sendBtn = TextView(this)
            sendBtn.text = "➤"
            sendBtn.gravity = Gravity.CENTER
            sendBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            sendBtn.setTypeface(sendBtn.typeface, Typeface.BOLD)
            sendBtn.setTextColor(kb.onAccent)
            sendBtn.background = roundedFill(kb.accent, 10)
            sendBtn.setOnClickListener {
                feedback(it)
                sendAction()
            }
            val lp = LinearLayout.LayoutParams(dp(42), dp(36))
            lp.setMargins(dp(4), 0, dp(2), 0)
            bar.addView(sendBtn, lp)
        }

        return bar
    }

    private fun iconButton(text: String, widthDp: Int, onClick: () -> Unit): TextView {
        val tv = TextView(this)
        tv.text = text
        tv.gravity = Gravity.CENTER
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
        tv.setTextColor(kb.text)
        tv.layoutParams = LinearLayout.LayoutParams(dp(widthDp), MATCH)
        tv.setOnClickListener {
            feedback(it)
            onClick()
        }
        return tv
    }

    private fun renderPage() {
        val host = keysHost ?: return
        dismissPopup()
        host.removeAllViews()
        when (page) {
            Page.EMOJI -> host.addView(buildEmojiPanel())
            Page.STICKER -> host.addView(buildStickerPanel())
            Page.CLIP -> host.addView(buildClipPanel())
            Page.SETTINGS -> host.addView(buildQuickSettingsPanel())
            else -> {
                val rows = Layouts.rows(page, enterLabel(), prefs.arabicLayout, prefs.numberRow)
                for (row in rows) host.addView(buildRow(row))
            }
        }
        updateSuggestions()
    }

    private fun renderLater() {
        handler.post { renderPage() }
    }

    private fun buildRow(keys: List<Key>): LinearLayout {
        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL
        row.layoutParams = LinearLayout.LayoutParams(MATCH, rowHeight())
        row.setPadding(dp(1), 0, dp(1), 0)
        for (k in keys) {
            val lp = LinearLayout.LayoutParams(0, MATCH, k.weight)
            lp.setMargins(dp(1), dp(2), dp(1), dp(2))
            row.addView(buildKey(k), lp)
        }
        return row
    }

    private fun roundedFill(color: Int, radiusDp: Int = 8): GradientDrawable {
        val g = GradientDrawable()
        g.shape = GradientDrawable.RECTANGLE
        g.cornerRadius = dp(radiusDp).toFloat()
        g.setColor(color)
        return g
    }

    private fun shape(color: Int): GradientDrawable {
        val g = GradientDrawable()
        g.shape = GradientDrawable.RECTANGLE
        g.cornerRadius = dp(9).toFloat()
        g.setColor(color)
        g.setStroke(dp(1), kb.divider)
        return g
    }

    private fun keyBg(fill: Int, pressed: Int): StateListDrawable {
        val sl = StateListDrawable()
        sl.addState(intArrayOf(android.R.attr.state_pressed), shape(pressed))
        sl.addState(intArrayOf(), shape(fill))
        return sl
    }

    private fun darken(c: Int): Int = Color.rgb(
        (Color.red(c) * 0.82f).toInt(),
        (Color.green(c) * 0.82f).toInt(),
        (Color.blue(c) * 0.82f).toInt(),
    )

    private fun buildKey(k: Key): View {
        val frame = FrameLayout(this)
        val special = k.type != KType.CHAR && k.type != KType.SPACE
        var fill = if (special) kb.action else kb.key
        var pressedFill = if (special) kb.actionPressed else kb.keyPressed
        var textColor = kb.text
        var label = k.label
        var size = if (special) 16f else charFontSp()

        when (k.type) {
            KType.ENTER -> {
                fill = kb.accent
                pressedFill = darken(kb.accent)
                textColor = kb.onAccent
                size = 20f
            }
            KType.SHIFT -> {
                if (page == Page.AR_SHIFT || page == Page.EN_SHIFT) {
                    textColor = kb.accent
                    if (page == Page.EN_SHIFT && shiftState == 2) label = "⇪"
                }
            }
            KType.SPACE -> {
                size = 14f
                textColor = kb.muted
            }
            else -> {}
        }

        frame.background = keyBg(fill, pressedFill)

        val mainTv = TextView(this)
        mainTv.text = label
        mainTv.gravity = Gravity.CENTER
        mainTv.isSingleLine = true
        mainTv.setTextColor(textColor)
        mainTv.setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
        if (special) mainTv.setTypeface(mainTv.typeface, Typeface.BOLD)
        frame.addView(mainTv, FrameLayout.LayoutParams(MATCH, MATCH))

        if (prefs.showHints && k.hint.isNotEmpty() && k.type == KType.CHAR) {
            val hintTv = TextView(this)
            hintTv.text = k.hint
            hintTv.setTextColor(kb.muted)
            hintTv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f)
            hintTv.setPadding(dp(4), dp(1), dp(4), 0)
            val hLp = FrameLayout.LayoutParams(WRAP, WRAP, Gravity.TOP or Gravity.START)
            frame.addView(hintTv, hLp)
        }

        var downY = 0f
        var longPressed = false
        var longRunnable: Runnable? = null

        frame.setOnTouchListener { v, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downY = e.rawY
                    longPressed = false
                    v.isPressed = true
                    feedback(v)

                    if (k.type == KType.BACK) {
                        backspace()
                        handler.postDelayed(repeatBack, 380)
                    } else {
                        if (prefs.keyPreview && k.type == KType.CHAR) {
                            showPopupChoices(v, listOf(k.label), isAlts = false)
                        }
                        if (k.alts.isNotEmpty()) {
                            val r = Runnable {
                                longPressed = true
                                v.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                                showPopupChoices(v, k.alts, isAlts = true)
                            }
                            longRunnable = r
                            handler.postDelayed(r, 320)
                        }
                    }
                }

                MotionEvent.ACTION_MOVE -> {
                    if (longPressed && popupAlts.isNotEmpty()) {
                        updatePopupSelection(e.rawX)
                    } else if (!longPressed && abs(e.rawY - downY) > dp(28) && k.type == KType.CHAR) {
                        longRunnable?.let { handler.removeCallbacks(it) }
                    }
                }

                MotionEvent.ACTION_UP -> {
                    longRunnable?.let { handler.removeCallbacks(it) }
                    longRunnable = null
                    if (k.type == KType.BACK) handler.removeCallbacks(repeatBack)
                    v.isPressed = false

                    val chosenAlt = if (longPressed && popupAlts.isNotEmpty()) {
                        popupAlts.getOrNull(popupSelectedIdx)
                    } else null
                    dismissPopup()

                    if (k.type != KType.BACK) {
                        if (chosenAlt != null) {
                            if (k.type == KType.ENTER) {
                                if (chosenAlt == "➤") sendAction() else insertNewline()
                            } else {
                                commitChar(chosenAlt)
                            }
                        } else if (
                            prefs.swipeHint &&
                            k.type == KType.CHAR &&
                            (e.rawY - downY) < -dp(24) &&
                            (k.hint.isNotEmpty() || k.alts.isNotEmpty())
                        ) {
                            val sec = if (k.hint.isNotEmpty()) k.hint else k.alts.first()
                            commitChar(sec)
                        } else {
                            onKeyTap(k)
                        }
                    }
                }

                MotionEvent.ACTION_CANCEL -> {
                    longRunnable?.let { handler.removeCallbacks(it) }
                    longRunnable = null
                    if (k.type == KType.BACK) handler.removeCallbacks(repeatBack)
                    v.isPressed = false
                    dismissPopup()
                }
            }
            true
        }

        return frame
    }

    private fun showPopupChoices(anchor: View, items: List<String>, isAlts: Boolean) {
        val r = root ?: return
        if (r.windowToken == null || items.isEmpty()) return
        dismissPopup()

        popupAlts = if (isAlts) items else emptyList()
        popupSelectedIdx = 0

        val itemW = dp(if (isAlts) 42 else 46)
        val itemH = dp(46)
        popupItemW = itemW

        val box = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            background = shape(kb.bar).apply { setStroke(dp(1), kb.accent) }
            setPadding(dp(4), dp(3), dp(4), dp(3))
        }

        for ((idx, txt) in items.withIndex()) {
            val tv = TextView(this).apply {
                text = txt
                gravity = Gravity.CENTER
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 21f)
                setTextColor(if (isAlts && idx == 0) kb.onAccent else kb.text)
                if (isAlts && idx == 0) background = roundedFill(kb.accent, 8)
            }
            box.addView(tv, LinearLayout.LayoutParams(itemW, itemH))
        }
        popupRow = box

        val totalW = itemW * items.size + dp(8)
        val totalH = itemH + dp(6)
        val pw = PopupWindow(box, totalW, totalH, false).apply {
            isTouchable = false
            elevation = dp(6).toFloat()
        }

        val loc = IntArray(2)
        anchor.getLocationInWindow(loc)
        val screenW = resources.displayMetrics.widthPixels
        var x = loc[0] + (anchor.width - totalW) / 2
        if (x < dp(4)) x = dp(4)
        if (x + totalW > screenW - dp(4)) x = screenW - totalW - dp(4)
        val y = (loc[1] - totalH - dp(4)).coerceAtLeast(0)

        popupOriginX = x + dp(4)
        try {
            pw.showAtLocation(r, Gravity.NO_GRAVITY, x, y)
            popup = pw
        } catch (e: Exception) {
        }
    }

    private fun updatePopupSelection(rawX: Float) {
        val row = popupRow ?: return
        if (popupAlts.isEmpty() || popupItemW <= 0) return
        val idx = ((rawX - popupOriginX) / popupItemW).toInt().coerceIn(0, popupAlts.size - 1)
        if (idx == popupSelectedIdx) return
        popupSelectedIdx = idx
        for (i in 0 until row.childCount) {
            val tv = row.getChildAt(i) as? TextView ?: continue
            if (i == idx) {
                tv.setTextColor(kb.onAccent)
                tv.background = roundedFill(kb.accent, 8)
            } else {
                tv.setTextColor(kb.text)
                tv.background = null
            }
        }
    }

    private fun dismissPopup() {
        try {
            popup?.dismiss()
        } catch (e: Exception) {
        }
        popup = null
        popupRow = null
        popupAlts = emptyList()
    }

    private fun bottomBarKeys(): List<Key> = listOf(
        Key(if (lang == "ar") "أبج" else "ABC", KType.ABC, weight = 1.6f),
        Key(" ", KType.SPACE, " ", 4f),
        Key("⌫", KType.BACK, weight = 1.6f),
    )

    private fun panelHeight(): Int = rowHeight() * 3

    private fun buildEmojiPanel(): View {
        val col = LinearLayout(this)
        col.orientation = LinearLayout.VERTICAL

        val tabs = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(2), dp(8), dp(2))
        }
        tabs.addView(tabPill("😊 الإيموجي", true) {}, LinearLayout.LayoutParams(0, dp(34), 1f))
        tabs.addView(tabPill("🖼️ ملصقاتي", false) {
            page = Page.STICKER
            renderPage()
        }, LinearLayout.LayoutParams(0, dp(34), 1f))
        col.addView(tabs, LinearLayout.LayoutParams(MATCH, dp(38)))

        val scroll = ScrollView(this)
        scroll.isVerticalScrollBarEnabled = false
        val grid = LinearLayout(this)
        grid.orientation = LinearLayout.VERTICAL
        for (chunk in Layouts.EMOJIS.chunked(8)) {
            val row = LinearLayout(this)
            row.orientation = LinearLayout.HORIZONTAL
            for (e in chunk) {
                val tv = TextView(this)
                tv.text = e
                tv.gravity = Gravity.CENTER
                tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
                tv.setOnClickListener {
                    feedback(it)
                    commit(e)
                }
                row.addView(tv, LinearLayout.LayoutParams(0, dp(46), 1f))
            }
            for (i in chunk.size until 8) row.addView(View(this), LinearLayout.LayoutParams(0, dp(46), 1f))
            grid.addView(row)
        }
        scroll.addView(grid)
        col.addView(scroll, LinearLayout.LayoutParams(MATCH, (panelHeight() - dp(38)).coerceAtLeast(dp(76))))
        col.addView(buildRow(bottomBarKeys()))
        return col
    }

    private fun tabPill(text: String, active: Boolean, onClick: () -> Unit): TextView {
        return TextView(this).apply {
            this.text = text
            gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f)
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(if (active) kb.onAccent else kb.text)
            background = roundedFill(if (active) kb.accent else kb.action, 8)
            setOnClickListener {
                feedback(it)
                onClick()
            }
            layoutParams = LinearLayout.LayoutParams(MATCH, MATCH).apply { setMargins(dp(4), 0, dp(4), 0) }
        }
    }

    private fun buildStickerPanel(): View {
        val col = LinearLayout(this)
        col.orientation = LinearLayout.VERTICAL

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), dp(4), dp(10), dp(4))
        }
        val title = TextView(this).apply {
            text = "🖼️ ملصقات الاستديو"
            setTextColor(kb.text)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14.5f)
            setTypeface(typeface, Typeface.BOLD)
        }
        header.addView(title, LinearLayout.LayoutParams(0, WRAP, 1f))

        val addBtn = TextView(this).apply {
            text = "+ من الاستديو"
            setTextColor(kb.onAccent)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setTypeface(typeface, Typeface.BOLD)
            background = roundedFill(kb.accent, 8)
            setPadding(dp(12), dp(6), dp(12), dp(6))
            setOnClickListener {
                feedback(it)
                openStickerPicker()
            }
        }
        header.addView(addBtn)
        col.addView(header, LinearLayout.LayoutParams(MATCH, dp(42)))

        var headerHeightDp = 42
        val activeSticker = selectedSticker?.takeIf { it.exists() }
        if (activeSticker != null) {
            headerHeightDp += 40
            val actionRow = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(8), dp(2), dp(8), dp(4))
            }
            actionRow.addView(tabPill("📤 مشاركة", false) {
                selectedSticker = null
                shareStickerExternally(activeSticker)
                renderPage()
            }, LinearLayout.LayoutParams(0, dp(34), 1f))
            actionRow.addView(tabPill("🗑️ حذف", true) {
                StickerManager.deleteSticker(activeSticker)
                selectedSticker = null
                renderPage()
            }, LinearLayout.LayoutParams(0, dp(34), 1f))
            actionRow.addView(tabPill("✕ إلغاء", false) {
                selectedSticker = null
                renderPage()
            }, LinearLayout.LayoutParams(0, dp(34), 0.8f))
            col.addView(actionRow, LinearLayout.LayoutParams(MATCH, dp(40)))
        }

        val stickers = StickerManager.listStickers(this)
        val scroll = ScrollView(this)
        scroll.isVerticalScrollBarEnabled = false
        val body = LinearLayout(this)
        body.orientation = LinearLayout.VERTICAL

        if (stickers.isEmpty()) {
            val emptyBox = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                setPadding(dp(16), dp(18), dp(16), dp(18))
            }
            val msg = TextView(this).apply {
                text = "لا توجد ملصقات بعد.\nأضف صوراً من الاستديو لإرسالها داخل المحادثات."
                gravity = Gravity.CENTER
                setTextColor(kb.muted)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            }
            val bigAdd = TextView(this).apply {
                text = "+ اختيار ملصقات من الاستديو"
                gravity = Gravity.CENTER
                setTextColor(kb.onAccent)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14.5f)
                setTypeface(typeface, Typeface.BOLD)
                background = roundedFill(kb.accent, 10)
                setPadding(dp(18), dp(10), dp(18), dp(10))
                setOnClickListener {
                    feedback(it)
                    openStickerPicker()
                }
            }
            emptyBox.addView(msg)
            emptyBox.addView(bigAdd, LinearLayout.LayoutParams(WRAP, WRAP).apply { topMargin = dp(12) })
            body.addView(emptyBox, LinearLayout.LayoutParams(MATCH, WRAP))
        } else {
            val thumbOpts = BitmapFactory.Options().apply { inSampleSize = 4 }
            val cols = 4
            for (chunk in stickers.chunked(cols)) {
                val row = LinearLayout(this)
                row.orientation = LinearLayout.HORIZONTAL
                row.setPadding(dp(6), dp(4), dp(6), dp(4))
                for (file in chunk) {
                    val isSel = activeSticker?.absolutePath == file.absolutePath
                    val holder = FrameLayout(this).apply {
                        background = shape(kb.key).apply {
                            if (isSel) setStroke(dp(2), kb.accent)
                        }
                        setPadding(dp(4), dp(4), dp(4), dp(4))
                    }
                    val iv = ImageView(this).apply {
                        scaleType = ImageView.ScaleType.FIT_CENTER
                        setImageBitmap(BitmapFactory.decodeFile(file.absolutePath, thumbOpts))
                    }
                    holder.addView(iv, FrameLayout.LayoutParams(MATCH, MATCH))
                    holder.setOnClickListener {
                        feedback(it)
                        selectedSticker = null
                        sendStickerToChat(file)
                    }
                    holder.setOnLongClickListener {
                        feedback(it)
                        selectedSticker = file
                        renderPage()
                        true
                    }
                    val lp = LinearLayout.LayoutParams(0, dp(74), 1f)
                    lp.setMargins(dp(3), dp(2), dp(3), dp(2))
                    row.addView(holder, lp)
                }
                for (i in chunk.size until cols) {
                    row.addView(View(this), LinearLayout.LayoutParams(0, dp(74), 1f))
                }
                body.addView(row)
            }
        }

        scroll.addView(body)
        col.addView(scroll, LinearLayout.LayoutParams(MATCH, (panelHeight() - dp(headerHeightDp)).coerceAtLeast(dp(76))))
        col.addView(buildRow(bottomBarKeys()))
        return col
    }

    private fun shareStickerExternally(file: File) {
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val share = Intent(Intent.ACTION_SEND).apply {
                type = "image/webp"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(Intent.createChooser(share, "مشاركة الملصق").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            requestHideSelf(0)
        } catch (e: Exception) {
            Toast.makeText(this, "تعذر مشاركة الملصق", Toast.LENGTH_SHORT).show()
        }
    }

    private fun buildClipPanel(): View {
        val col = LinearLayout(this)
        col.orientation = LinearLayout.VERTICAL

        val header = LinearLayout(this)
        header.orientation = LinearLayout.HORIZONTAL
        header.gravity = Gravity.CENTER_VERTICAL
        header.setPadding(dp(12), 0, dp(12), 0)
        val title = TextView(this)
        title.text = "📋 الحافظة"
        title.setTextColor(kb.text)
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        title.setTypeface(title.typeface, Typeface.BOLD)
        header.addView(title, LinearLayout.LayoutParams(0, WRAP, 1f))
        val clear = TextView(this)
        clear.text = "مسح الكل"
        clear.setTextColor(kb.accent)
        clear.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        clear.setPadding(dp(8), dp(8), dp(8), dp(8))
        clear.setOnClickListener {
            prefs.saveClips(emptyList())
            renderPage()
        }
        header.addView(clear)
        col.addView(header, LinearLayout.LayoutParams(MATCH, dp(40)))

        val scroll = ScrollView(this)
        scroll.isVerticalScrollBarEnabled = false
        val list = LinearLayout(this)
        list.orientation = LinearLayout.VERTICAL
        val items = prefs.clips()
        if (items.isEmpty()) {
            val empty = TextView(this)
            empty.text = "لا توجد عناصر منسوخة بعد. انسخ نصاً وسيظهر هنا."
            empty.setTextColor(kb.muted)
            empty.gravity = Gravity.CENTER
            empty.setPadding(dp(16), dp(24), dp(16), dp(24))
            list.addView(empty, LinearLayout.LayoutParams(MATCH, WRAP))
        }
        items.forEachIndexed { index, text ->
            val line = LinearLayout(this)
            line.orientation = LinearLayout.HORIZONTAL
            line.gravity = Gravity.CENTER_VERTICAL
            line.background = shape(kb.key)
            val t = TextView(this)
            t.text = text.replace("\n", " ")
            t.setTextColor(kb.text)
            t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            t.maxLines = 1
            t.ellipsize = TextUtils.TruncateAt.END
            t.gravity = Gravity.CENTER_VERTICAL or Gravity.START
            t.setPadding(dp(12), 0, dp(8), 0)
            t.setOnClickListener {
                feedback(it)
                commit(text)
            }
            line.addView(t, LinearLayout.LayoutParams(0, MATCH, 1f))
            val x = TextView(this)
            x.text = "✕"
            x.gravity = Gravity.CENTER
            x.setTextColor(kb.muted)
            x.setOnClickListener {
                val all = prefs.clips().toMutableList()
                if (index < all.size) all.removeAt(index)
                prefs.saveClips(all)
                renderPage()
            }
            line.addView(x, LinearLayout.LayoutParams(dp(40), MATCH))
            val lp = LinearLayout.LayoutParams(MATCH, dp(42))
            lp.setMargins(dp(6), dp(3), dp(6), dp(3))
            list.addView(line, lp)
        }
        scroll.addView(list)
        col.addView(scroll, LinearLayout.LayoutParams(MATCH, (panelHeight() - dp(40)).coerceAtLeast(dp(76))))
        col.addView(buildRow(bottomBarKeys()))
        return col
    }

    private fun buildQuickSettingsPanel(): View {
        val col = LinearLayout(this)
        col.orientation = LinearLayout.VERTICAL

        val scroll = ScrollView(this)
        scroll.isVerticalScrollBarEnabled = false
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutDirection = View.LAYOUT_DIRECTION_RTL
            setPadding(dp(10), dp(6), dp(10), dp(6))
        }

        fun sectionTitle(t: String): TextView = TextView(this).apply {
            text = t
            setTextColor(kb.muted)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
            setTypeface(typeface, Typeface.BOLD)
            setPadding(dp(2), dp(6), dp(2), dp(4))
        }

        fun pillsRow(items: List<Pair<String, Boolean>>, onPick: (Int) -> Unit): LinearLayout {
            val r = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            items.forEachIndexed { idx, (label, selected) ->
                val btn = TextView(this).apply {
                    text = label
                    gravity = Gravity.CENTER
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
                    setTypeface(typeface, Typeface.BOLD)
                    setTextColor(if (selected) kb.onAccent else kb.text)
                    background = roundedFill(if (selected) kb.accent else kb.key, 8)
                    setOnClickListener {
                        feedback(it)
                        onPick(idx)
                    }
                }
                val lp = LinearLayout.LayoutParams(0, dp(36), 1f)
                lp.setMargins(dp(2), 0, dp(2), 0)
                r.addView(btn, lp)
            }
            return r
        }

        box.addView(sectionTitle("تخطيط الأحرف العربية"))
        box.addView(
            pillsRow(
                listOf(
                    "مدمج كبير" to (prefs.arabicLayout == 0),
                    "ضخم ٨/صف" to (prefs.arabicLayout == 1),
                    "كامل" to (prefs.arabicLayout == 2),
                ),
            ) {
                prefs.arabicLayout = it
                renderPage()
            },
        )

        box.addView(sectionTitle("حجم الأزرار"))
        box.addView(
            pillsRow(
                listOf(
                    "صغير" to (prefs.keyHeight == 0),
                    "متوسط" to (prefs.keyHeight == 1),
                    "كبير" to (prefs.keyHeight == 2),
                    "ضخم" to (prefs.keyHeight == 3),
                ),
            ) {
                prefs.keyHeight = it
                renderPage()
            },
        )

        box.addView(sectionTitle("المظهر"))
        box.addView(
            pillsRow(
                listOf(
                    "ثلجي ❄️" to (prefs.theme == "snow"),
                    "أسود 🌑" to (prefs.theme == "black"),
                    "ليلي 🌌" to (prefs.theme == "midnight"),
                ),
            ) { idx ->
                prefs.theme = listOf("snow", "black", "midnight")[idx]
                buildUi()
            },
        )

        box.addView(sectionTitle("تبديلات سريعة"))
        box.addView(
            pillsRow(
                listOf(
                    "زر الإرسال ➤" to prefs.dedicatedSend,
                    "صف الأرقام" to prefs.numberRow,
                    "اهتزاز" to prefs.haptic,
                ),
            ) { idx ->
                when (idx) {
                    0 -> {
                        prefs.dedicatedSend = !prefs.dedicatedSend
                        buildUi()
                    }
                    1 -> {
                        prefs.numberRow = !prefs.numberRow
                        renderPage()
                    }
                    2 -> {
                        prefs.haptic = !prefs.haptic
                        haptic = prefs.haptic
                        renderPage()
                    }
                }
            },
        )

        val fullBtn = TextView(this).apply {
            text = "⚙️ فتح قائمة ضبط الإعدادات الكاملة (الحساب، النسخ الاحتياطي، الملصقات)"
            gravity = Gravity.CENTER
            setTextColor(kb.onAccent)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f)
            setTypeface(typeface, Typeface.BOLD)
            background = roundedFill(kb.accent, 10)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            setOnClickListener {
                feedback(it)
                openSettings()
            }
        }
        box.addView(fullBtn, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(10) })

        scroll.addView(box)
        col.addView(scroll, LinearLayout.LayoutParams(MATCH, panelHeight().coerceAtLeast(dp(76))))
        col.addView(buildRow(bottomBarKeys()))
        return col
    }

    private fun onKeyTap(k: Key) {
        when (k.type) {
            KType.CHAR -> commitChar(k.out)
            KType.SPACE -> commit(" ")
            KType.BACK -> backspace()
            KType.ENTER -> enter()
            KType.SHIFT -> {
                toggleShift()
                renderLater()
            }
            KType.SYM -> {
                page = Page.SYM
                renderLater()
            }
            KType.ABC -> {
                shiftState = 0
                page = mainPage()
                renderLater()
            }
            KType.EMOJI -> {
                page = Page.EMOJI
                renderLater()
            }
            KType.STICKER -> {
                page = Page.STICKER
                renderLater()
            }
            KType.LANG -> {
                lang = if (lang == "ar") "en" else "ar"
                prefs.lang = lang
                shiftState = 0
                page = mainPage()
                renderLater()
            }
        }
    }

    private fun commitChar(s: String) {
        commit(s)
        if (page == Page.EN_SHIFT && shiftState == 1) {
            shiftState = 0
            page = Page.EN
            renderLater()
        }
    }

    private fun toggleShift() {
        when (page) {
            Page.AR -> page = Page.AR_SHIFT
            Page.AR_SHIFT -> page = Page.AR
            Page.EN -> {
                shiftState = 1
                page = Page.EN_SHIFT
            }
            Page.EN_SHIFT -> {
                if (shiftState == 1) {
                    shiftState = 2
                } else {
                    shiftState = 0
                    page = Page.EN
                }
            }
            Page.SYM -> page = Page.SYM2
            Page.SYM2 -> page = Page.SYM
            else -> {}
        }
    }

    private fun commit(s: String) {
        currentInputConnection?.commitText(s, 1)
        updateSuggestions()
    }

    private fun backspace() {
        val ic = currentInputConnection ?: return
        val sel = ic.getSelectedText(0)
        if (!sel.isNullOrEmpty()) {
            ic.commitText("", 1)
        } else {
            sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)
        }
        updateSuggestions()
    }

    private fun insertNewline() {
        sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
    }

    private fun sendAction() {
        val ic = currentInputConnection ?: return
        val info = currentInputEditorInfo
        val opts = info?.imeOptions ?: 0
        val action = opts and EditorInfo.IME_MASK_ACTION
        val targetAction = when (action) {
            EditorInfo.IME_ACTION_SEARCH,
            EditorInfo.IME_ACTION_GO,
            EditorInfo.IME_ACTION_NEXT,
            EditorInfo.IME_ACTION_DONE,
            EditorInfo.IME_ACTION_SEND -> action
            else -> EditorInfo.IME_ACTION_SEND
        }
        val handled = ic.performEditorAction(targetAction)
        if (!handled) {
            sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
        }
    }

    private fun enter() {
        val info = currentInputEditorInfo
        val opts = info?.imeOptions ?: 0
        val action = opts and EditorInfo.IME_MASK_ACTION
        val noAction = (opts and EditorInfo.IME_FLAG_NO_ENTER_ACTION) != 0

        if (prefs.enterSends) {
            sendAction()
            return
        }
        if (!noAction && action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED) {
            currentInputConnection?.performEditorAction(action)
        } else {
            insertNewline()
        }
    }

    private fun enterLabel(): String {
        val info = currentInputEditorInfo
        val opts = info?.imeOptions ?: 0
        val action = opts and EditorInfo.IME_MASK_ACTION
        val noAction = (opts and EditorInfo.IME_FLAG_NO_ENTER_ACTION) != 0
        if (prefs.enterSends && (noAction || action == EditorInfo.IME_ACTION_NONE || action == EditorInfo.IME_ACTION_UNSPECIFIED)) {
            return "➤"
        }
        if (noAction) return "↵"
        return when (action) {
            EditorInfo.IME_ACTION_GO, EditorInfo.IME_ACTION_SEND -> "➤"
            EditorInfo.IME_ACTION_SEARCH -> "🔍"
            EditorInfo.IME_ACTION_NEXT -> "⇥"
            EditorInfo.IME_ACTION_DONE -> "✓"
            else -> if (prefs.enterSends) "➤" else "↵"
        }
    }

    private fun sendStickerToChat(file: File) {
        val ic = currentInputConnection
        val info = currentInputEditorInfo
        if (ic == null || info == null) {
            Toast.makeText(this, "افتح محادثة أولاً لإرسال الملصق", Toast.LENGTH_SHORT).show()
            return
        }

        val accepted = EditorInfoCompat.getContentMimeTypes(info)
        val target = if (accepted.isNotEmpty()) {
            StickerManager.getSendableFileAndMime(this, file, accepted)
        } else null

        if (target == null) {
            Toast.makeText(this, "هذا الحقل لا يدعم الملصقات مباشرة — جاري المشاركة", Toast.LENGTH_SHORT).show()
            shareStickerExternally(file)
            return
        }

        try {
            val (sendFile, mime) = target
            val contentUri = FileProvider.getUriForFile(this, "$packageName.fileprovider", sendFile)
            val contentInfo = InputContentInfoCompat(
                contentUri,
                ClipDescription("ملصق", arrayOf(mime)),
                null,
            )
            val flags = InputConnectionCompat.INPUT_CONTENT_GRANT_READ_URI_PERMISSION
            val ok = InputConnectionCompat.commitContent(ic, info, contentInfo, flags, null)
            if (!ok) {
                Toast.makeText(this, "تعذر إرسال الملصق في هذا التطبيق", Toast.LENGTH_SHORT).show()
            }
        } catch (e: Exception) {
            Toast.makeText(this, "حدث خطأ أثناء إرسال الملصق", Toast.LENGTH_SHORT).show()
        }
    }

    private fun openStickerPicker() {
        val i = Intent(this, StickerPickerActivity::class.java)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(i)
        requestHideSelf(0)
    }

    private fun feedback(v: View) {
        if (haptic) v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        if (sound) {
            try {
                (getSystemService(Context.AUDIO_SERVICE) as AudioManager)
                    .playSoundEffect(AudioManager.FX_KEYPRESS_STANDARD)
            } catch (e: Exception) {
            }
        }
    }

    private fun openSettings() {
        val i = Intent(this, SettingsActivity::class.java)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(i)
        requestHideSelf(0)
    }

    private fun trailingWord(s: String): String {
        var i = s.length
        while (i > 0) {
            val ch = s[i - 1]
            if (Character.isLetter(ch) || Character.getType(ch) == Character.NON_SPACING_MARK.toInt()) i-- else break
        }
        return s.substring(i)
    }

    private fun updateSuggestions() {
        if (suggestionViews.isEmpty()) return
        if (!suggestOn || !prefs.suggestEnabled) {
            suggestions = listOf("", "", "")
        } else {
            val before = currentInputConnection?.getTextBeforeCursor(40, 0)?.toString() ?: ""
            val word = trailingWord(before)
            val rest = before.substring(0, before.length - word.length).trim()
            val prev = trailingWord(rest)
            val arabic = when (page) {
                Page.AR, Page.AR_SHIFT -> true
                Page.EN, Page.EN_SHIFT -> false
                else -> lang == "ar"
            }
            suggestions = Words.suggest(word, prev, arabic)
        }
        for (i in 0 until 3) suggestionViews[i].text = suggestions[i]
    }

    private fun applySuggestion(i: Int) {
        val s = suggestions.getOrNull(i) ?: return
        if (s.isEmpty()) return
        val ic = currentInputConnection ?: return
        val before = ic.getTextBeforeCursor(40, 0)?.toString() ?: ""
        val word = trailingWord(before)
        ic.beginBatchEdit()
        if (word.isNotEmpty()) ic.deleteSurroundingText(word.length, 0)
        ic.commitText("$s ", 1)
        ic.endBatchEdit()
        updateSuggestions()
    }

    private fun captureClip(cm: ClipboardManager) {
        try {
            val clip = cm.primaryClip ?: return
            if (clip.itemCount == 0) return
            val text = clip.getItemAt(0).coerceToText(this)?.toString()?.trim() ?: return
            if (text.isEmpty() || text.length > 2000) return
            val list = prefs.clips().toMutableList()
            list.remove(text)
            list.add(0, text)
            prefs.saveClips(list.take(25))
        } catch (e: Exception) {
        }
    }
}
__ARABIKEY_EOF__

cat <<'__ARABIKEY_EOF__' > app/src/main/java/com/arabikey/keyboard/SettingsActivity.kt
package com.arabikey.keyboard

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.FileProvider
import androidx.core.view.ViewCompat
import androidx.core.view.inputmethod.EditorInfoCompat
import androidx.core.view.inputmethod.InputConnectionCompat
import java.io.FileInputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class SettingsActivity : Activity() {

    companion object {
        private const val REQ_BACKUP_SAVE = 2001
        private const val REQ_BACKUP_RESTORE = 2002
    }

    private val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
    private val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

    private lateinit var prefs: Prefs
    private var t: KbTheme = KbTheme.SNOW
    private var authRegisterMode = true

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = Prefs(this)
    }

    override fun onResume() {
        super.onResume()
        build()
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun keyboardEnabled(): Boolean {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        return imm.enabledInputMethodList.any { it.packageName == packageName }
    }

    private fun keyboardSelected(): Boolean {
        val cur = Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD) ?: ""
        return cur.startsWith("$packageName/")
    }

    private fun build() {
        t = KbTheme.byName(prefs.theme)
        window.statusBarColor = t.bg
        window.navigationBarColor = t.bg
        if (Build.VERSION.SDK_INT >= 26) {
            window.decorView.systemUiVisibility = if (t.isLight) {
                View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
            } else 0
        } else {
            window.decorView.systemUiVisibility = if (t.isLight) View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR else 0
        }

        val scroll = ScrollView(this)
        scroll.setBackgroundColor(t.bg)
        scroll.layoutDirection = View.LAYOUT_DIRECTION_RTL
        val col = LinearLayout(this)
        col.orientation = LinearLayout.VERTICAL
        col.setPadding(dp(18), dp(38), dp(18), dp(36))
        scroll.addView(col, ViewGroup.LayoutParams(MATCH, WRAP))

        col.addView(label("كيبورد ذكي — الإعدادات", 26f, true, t.text))
        col.addView(label("لوحة مفاتيح عربية متكاملة بأزرار كبيرة وملصقات ونسخ احتياطي", 13.5f, false, t.muted))

        val enabled = keyboardEnabled()
        val selected = keyboardSelected()
        col.addView(
            card(
                "١) التفعيل والتشغيل",
                when {
                    enabled && selected -> "✅ الكيبورد مفعّل ومختار حالياً"
                    enabled -> "مفعّل — باقي اختياره كلوحة مفاتيح افتراضية"
                    else -> "فعّل الكيبورد أولاً ثم اختره"
                },
            ) { box ->
                box.addView(button("فتح إعدادات لوحات المفاتيح", !enabled) {
                    startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
                })
                box.addView(button("اختيار الكيبورد", enabled && !selected) {
                    val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                    imm.showInputMethodPicker()
                })
            },
        )

        col.addView(buildAccountCard())
        col.addView(buildBackupCard())

        col.addView(
            card("٤) تخطيط الأحرف وتكبير الأزرار", "ضم الأحرف المتقاربة وإظهار الأحرف الناقصة والهمزات") { box ->
                box.addView(label("تخطيط الأحرف العربية", 13.5f, true, t.muted))
                val layoutRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
                listOf("مدمج كبير", "ضخم ٨/صف", "كامل").forEachIndexed { idx, title ->
                    layoutRow.addView(optionButton(title, prefs.arabicLayout == idx) {
                        prefs.arabicLayout = idx
                        build()
                    }, weighted())
                }
                box.addView(layoutRow)

                box.addView(label("ارتفاع الأزرار", 13.5f, true, t.muted).apply {
                    (layoutParams as LinearLayout.LayoutParams).topMargin = dp(12)
                })
                val sizeRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
                listOf("صغير", "متوسط", "كبير", "ضخم").forEachIndexed { i, name ->
                    sizeRow.addView(optionButton(name, prefs.keyHeight == i) {
                        prefs.keyHeight = i
                        build()
                    }, weighted())
                }
                box.addView(sizeRow)

                box.addView(label("حجم خط الأحرف", 13.5f, true, t.muted).apply {
                    (layoutParams as LinearLayout.LayoutParams).topMargin = dp(12)
                })
                val fontRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
                listOf("عادي", "كبير", "ضخم").forEachIndexed { i, name ->
                    fontRow.addView(optionButton(name, prefs.fontSize == i) {
                        prefs.fontSize = i
                        build()
                    }, weighted())
                }
                box.addView(fontRow)

                box.addView(switchItem("صف أرقام علوي دائم", prefs.numberRow) { prefs.numberRow = it })
                box.addView(switchItem("إظهار تلميح الأحرف المدمجة في الزاوية", prefs.showHints) { prefs.showHints = it })
                box.addView(switchItem("السحب للأعلى لكتابة الحرف المدمج", prefs.swipeHint) { prefs.swipeHint = it })
                box.addView(switchItem("معاينة منبثقة للحرف عند الضغط", prefs.keyPreview) { prefs.keyPreview = it })
            },
        )

        col.addView(
            card("٥) زر الإرسال والذكاء", "إرسال فوري في الدردشات والبحث") { box ->
                box.addView(switchItem("إظهار زر إرسال مستقل (➤) في الشريط", prefs.dedicatedSend) { prefs.dedicatedSend = it })
                box.addView(switchItem("تحويل مفتاح الإدخال (↵) إلى إرسال مباشر", prefs.enterSends) { prefs.enterSends = it })
                box.addView(switchItem("اقتراحات الكلمات التلقائية", prefs.suggestEnabled) { prefs.suggestEnabled = it })
                box.addView(switchItem("حفظ المنسوخات في الحافظة الذكية", prefs.clipboardEnabled) { prefs.clipboardEnabled = it })
            },
        )

        col.addView(buildStickersCard())

        col.addView(
            card("٧) المظهر والتفاعل", "اختر الثيم المناسب لعينيك") { box ->
                val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
                val themes = listOf("snow" to "ثلجي ❄️", "black" to "أسود 🌑", "midnight" to "ليلي 🌌")
                for ((id, title) in themes) {
                    row.addView(optionButton(title, prefs.theme == id) {
                        prefs.theme = id
                        build()
                    }, weighted())
                }
                box.addView(row)
                box.addView(switchItem("اهتزاز خفيف مع الأزرار", prefs.haptic) { prefs.haptic = it })
                box.addView(switchItem("صوت النقر", prefs.sound) { prefs.sound = it })
            },
        )

        col.addView(buildTestChatCard())

        setContentView(scroll)
    }

    private fun buildAccountCard(): View {
        val acc = AccountManager.currentAccount(prefs)
        val subtitle = if (acc != null) "مسجّل دخول: ${acc.name} (${acc.email})" else "سجّل بإيميلك لحفظ بياناتك مع النسخة الاحتياطية"
        return card("٢) الحساب والتسجيل بالإيميل", subtitle) { box ->
            if (acc != null) {
                box.addView(label("📧 ${acc.email}", 14f, true, t.accent))
                val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
                row.addView(optionButton("تغيير كلمة المرور", false) {
                    showChangePasswordDialog()
                }, weighted())
                row.addView(optionButton("تسجيل الخروج", false) {
                    AccountManager.logout(prefs)
                    Toast.makeText(this, "تم تسجيل الخروج", Toast.LENGTH_SHORT).show()
                    build()
                }, weighted())
                box.addView(row)
            } else {
                val modeRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
                modeRow.addView(optionButton("حساب جديد", authRegisterMode) {
                    authRegisterMode = true
                    build()
                }, weighted())
                modeRow.addView(optionButton("تسجيل الدخول", !authRegisterMode) {
                    authRegisterMode = false
                    build()
                }, weighted())
                box.addView(modeRow)

                val nameEt = if (authRegisterMode) inputField("الاسم (اختياري)", InputType.TYPE_CLASS_TEXT) else null
                nameEt?.let { box.addView(it, fieldLp()) }

                val emailEt = inputField("البريد الإلكتروني (example@mail.com)", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS)
                box.addView(emailEt, fieldLp())

                val passEt = inputField("كلمة المرور (٤ أحرف فأكثر)", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
                box.addView(passEt, fieldLp())

                box.addView(button(if (authRegisterMode) "إنشاء الحساب وحفظ الإيميل" else "تسجيل الدخول", true) {
                    val email = emailEt.text.toString()
                    val pass = passEt.text.toString()
                    val res = if (authRegisterMode) {
                        AccountManager.register(prefs, email, nameEt?.text?.toString() ?: "", pass)
                    } else {
                        AccountManager.login(prefs, email, pass)
                    }
                    res.onSuccess {
                        Toast.makeText(this, "أهلاً ${it.name}!", Toast.LENGTH_SHORT).show()
                        build()
                    }.onFailure { err ->
                        Toast.makeText(this, err.message ?: "حدث خطأ", Toast.LENGTH_SHORT).show()
                    }
                })
            }
        }
    }

    private fun showChangePasswordDialog() {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(12), dp(20), dp(4))
        }
        val oldEt = inputField("كلمة المرور الحالية", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        val newEt = inputField("كلمة المرور الجديدة", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        box.addView(oldEt, fieldLp())
        box.addView(newEt, fieldLp())

        AlertDialog.Builder(this)
            .setTitle("تغيير كلمة المرور")
            .setView(box)
            .setPositiveButton("حفظ") { _, _ ->
                AccountManager.changePassword(prefs, oldEt.text.toString(), newEt.text.toString())
                    .onSuccess { Toast.makeText(this, "تم تحديث كلمة المرور", Toast.LENGTH_SHORT).show() }
                    .onFailure { Toast.makeText(this, it.message ?: "خطأ", Toast.LENGTH_SHORT).show() }
            }
            .setNegativeButton("إلغاء", null)
            .show()
    }

    private fun buildBackupCard(): View {
        val last = prefs.lastBackupTime
        val dateText = if (last > 0L) {
            "آخر نسخة: " + SimpleDateFormat("yyyy/MM/dd HH:mm", Locale.getDefault()).format(Date(last))
        } else {
            "يشمل: الإعدادات + الحافظة + الحساب + جميع الملصقات"
        }

        return card("٣) النسخ الاحتياطي والاستعادة", dateText) { box ->
            box.addView(button("💾 أخذ نسخة احتياطية وحفظها كملف (.zip)", true) {
                val name = "ArabiKey_Backup_${SimpleDateFormat("yyyyMMdd_HHmm", Locale.US).format(Date())}.zip"
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/zip"
                    putExtra(Intent.EXTRA_TITLE, name)
                }
                startActivityForResult(intent, REQ_BACKUP_SAVE)
            })

            box.addView(button("📧 إرسال النسخة الاحتياطية إلى الإيميل", false) {
                val file = BackupManager.prepareEmailBackupFile(this)
                if (file == null) {
                    Toast.makeText(this, "تعذر تجهيز ملف النسخة", Toast.LENGTH_SHORT).show()
                    return@button
                }
                try {
                    val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                    val email = prefs.userEmail
                    val sendIntent = Intent(Intent.ACTION_SEND).apply {
                        type = "application/zip"
                        if (email.isNotBlank()) putExtra(Intent.EXTRA_EMAIL, arrayOf(email))
                        putExtra(Intent.EXTRA_SUBJECT, "نسخة احتياطية — كيبورد ذكي")
                        putExtra(Intent.EXTRA_TEXT, "ملف النسخة الاحتياطية لإعدادات وحافظة وملصقات كيبورد ذكي.")
                        putExtra(Intent.EXTRA_STREAM, uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(Intent.createChooser(sendIntent, "إرسال النسخة الاحتياطية عبر الإيميل"))
                } catch (e: Exception) {
                    Toast.makeText(this, "لا يوجد تطبيق بريد متاح", Toast.LENGTH_SHORT).show()
                }
            })

            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            row.addView(optionButton("حفظ نسخة محلية سريعة", false) {
                if (BackupManager.saveLocalSnapshot(this) != null) {
                    Toast.makeText(this, "تم حفظ النسخة المحلية بنجاح", Toast.LENGTH_SHORT).show()
                    build()
                } else {
                    Toast.makeText(this, "فشل حفظ النسخة", Toast.LENGTH_SHORT).show()
                }
            }, weighted())

            row.addView(optionButton("استعادة من النسخة المحلية", false) {
                if (!BackupManager.hasLocalSnapshot(this)) {
                    Toast.makeText(this, "لا توجد نسخة محلية محفوظة بعد", Toast.LENGTH_SHORT).show()
                    return@optionButton
                }
                FileInputStream(BackupManager.localSnapshotFile(this)).use { fis ->
                    handleRestoreResult(BackupManager.restoreFromStream(this, fis))
                }
            }, weighted())
            box.addView(row)

            box.addView(button("♻️ استعادة من ملف نسخة احتياطية (.zip)", false) {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip", "application/octet-stream"))
                }
                startActivityForResult(intent, REQ_BACKUP_RESTORE)
            })
        }
    }

    private fun handleRestoreResult(res: Result<BackupManager.RestoreResult>) {
        res.onSuccess { r ->
            val msg = "تمت الاستعادة! (${r.stickerCount} ملصق، ${r.clipCount} عنصر حافظة)"
            Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
            build()
        }.onFailure { err ->
            Toast.makeText(this, err.message ?: "فشلت الاستعادة", Toast.LENGTH_SHORT).show()
        }
    }

    private fun buildStickersCard(): View {
        val stickers = StickerManager.listStickers(this)
        return card("٦) ملصقات الاستديو (${stickers.size})", "أضف صوراً من الاستديو وأرسلها من زر 🖼️ في الكيبورد") { box ->
            box.addView(button("+ إضافة ملصقات من الاستديو", true) {
                startActivity(Intent(this, StickerPickerActivity::class.java))
            })

            if (stickers.isNotEmpty()) {
                val thumbOpts = BitmapFactory.Options().apply { inSampleSize = 4 }
                val previewRow = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    setPadding(0, dp(10), 0, 0)
                }
                for (file in stickers.take(5)) {
                    val frame = FrameLayout(this).apply {
                        background = rounded(t.bg)
                        setPadding(dp(4), dp(4), dp(4), dp(4))
                    }
                    val iv = ImageView(this).apply {
                        scaleType = ImageView.ScaleType.FIT_CENTER
                        setImageBitmap(BitmapFactory.decodeFile(file.absolutePath, thumbOpts))
                    }
                    frame.addView(iv, FrameLayout.LayoutParams(MATCH, MATCH))
                    frame.setOnClickListener {
                        AlertDialog.Builder(this)
                            .setTitle("حذف الملصق")
                            .setMessage("هل تريد حذف هذا الملصق؟")
                            .setPositiveButton("حذف") { _, _ ->
                                StickerManager.deleteSticker(file)
                                build()
                            }
                            .setNegativeButton("إلغاء", null)
                            .show()
                    }
                    val lp = LinearLayout.LayoutParams(0, dp(56), 1f).apply {
                        marginStart = dp(3)
                        marginEnd = dp(3)
                    }
                    previewRow.addView(frame, lp)
                }
                box.addView(previewRow)
            }
        }
    }

    private fun buildTestChatCard(): View {
        return card("٨) جرّب الكتابة، زر الإرسال، والملصقات", "اضغط هنا واكتب أو أرسل ملصقاً للتجربة") { box ->
            val logTv = label("آخر إجراء: جاهز للتجربة", 13f, false, t.muted)
            val stickerPreview = ImageView(this).apply {
                visibility = View.GONE
                scaleType = ImageView.ScaleType.FIT_CENTER
            }

            val mimeTypes = arrayOf("image/webp.wasticker", "image/webp", "image/png", "image/jpeg", "image/*")
            val et = object : EditText(this) {
                override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
                    val ic = super.onCreateInputConnection(outAttrs) ?: return null
                    EditorInfoCompat.setContentMimeTypes(outAttrs, mimeTypes)
                    return InputConnectionCompat.createWrapper(this, ic, outAttrs)
                }
            }
            et.hint = "اكتب رسالة وجرب زر الإرسال ➤ أو أرسل ملصقاً..."
            et.setTextColor(t.text)
            et.setHintTextColor(t.muted)
            et.minLines = 2
            et.imeOptions = EditorInfo.IME_ACTION_SEND
            et.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            et.gravity = Gravity.TOP or Gravity.START
            et.background = rounded(t.bg)
            et.setPadding(dp(12), dp(12), dp(12), dp(12))

            et.setOnEditorActionListener { v, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_SEND) {
                    val sent = v.text.toString().trim()
                    logTv.text = if (sent.isNotEmpty()) {
                        et.setText("")
                        "✅ تم إرسال الرسالة: $sent"
                    } else {
                        "✅ تم الضغط على زر الإرسال"
                    }
                    true
                } else false
            }

            ViewCompat.setOnReceiveContentListener(et, mimeTypes) { _, payload ->
                val uri = payload.clip.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
                if (uri != null) {
                    try {
                        contentResolver.openInputStream(uri)?.use { stream ->
                            val bmp = BitmapFactory.decodeStream(stream)
                            stickerPreview.setImageBitmap(bmp)
                            stickerPreview.visibility = View.VISIBLE
                            logTv.text = "✅ تم استلام ملصق من الكيبورد بنجاح!"
                        }
                    } catch (e: Exception) {
                    }
                    null
                } else payload
            }

            box.addView(et, LinearLayout.LayoutParams(MATCH, WRAP))
            box.addView(logTv, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(8) })
            box.addView(stickerPreview, LinearLayout.LayoutParams(dp(96), dp(96)).apply { topMargin = dp(6) })
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode != RESULT_OK || data?.data == null) return
        val uri = data.data!!

        if (requestCode == REQ_BACKUP_SAVE) {
            val ok = contentResolver.openOutputStream(uri)?.use { out ->
                BackupManager.createBackupZip(this, out)
            } ?: false
            Toast.makeText(
                this,
                if (ok) "تم حفظ ملف النسخة الاحتياطية بنجاح" else "تعذر حفظ الملف",
                Toast.LENGTH_SHORT,
            ).show()
            build()
        } else if (requestCode == REQ_BACKUP_RESTORE) {
            contentResolver.openInputStream(uri)?.use { input ->
                handleRestoreResult(BackupManager.restoreFromStream(this, input))
            } ?: Toast.makeText(this, "تعذر فتح ملف النسخة الاحتياطية", Toast.LENGTH_SHORT).show()
        }
    }

    private fun rounded(fill: Int, stroke: Int = t.divider): GradientDrawable {
        val g = GradientDrawable()
        g.shape = GradientDrawable.RECTANGLE
        g.cornerRadius = dp(12).toFloat()
        g.setColor(fill)
        g.setStroke(dp(1), stroke)
        return g
    }

    private fun label(text: String, size: Float, bold: Boolean, color: Int): TextView {
        val tv = TextView(this)
        tv.text = text
        tv.setTextColor(color)
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
        if (bold) tv.setTypeface(tv.typeface, Typeface.BOLD)
        tv.gravity = Gravity.START
        tv.layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { bottomMargin = dp(6) }
        return tv
    }

    private fun card(title: String, subtitle: String, content: (LinearLayout) -> Unit): View {
        val box = LinearLayout(this)
        box.orientation = LinearLayout.VERTICAL
        box.background = rounded(t.bar)
        box.setPadding(dp(16), dp(14), dp(16), dp(14))
        box.addView(label(title, 16.5f, true, t.text))
        if (subtitle.isNotEmpty()) box.addView(label(subtitle, 13f, false, t.muted))
        content(box)
        box.layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(14) }
        return box
    }

    private fun button(text: String, primary: Boolean, onClick: () -> Unit): TextView {
        val tv = TextView(this)
        tv.text = text
        tv.gravity = Gravity.CENTER
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14.5f)
        tv.setTypeface(tv.typeface, Typeface.BOLD)
        tv.setTextColor(if (primary) t.onAccent else t.text)
        tv.background = rounded(if (primary) t.accent else t.action)
        tv.setOnClickListener { onClick() }
        tv.layoutParams = LinearLayout.LayoutParams(MATCH, dp(46)).apply { topMargin = dp(8) }
        return tv
    }

    private fun optionButton(text: String, selected: Boolean, onClick: () -> Unit): TextView {
        val tv = TextView(this)
        tv.text = text
        tv.gravity = Gravity.CENTER
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f)
        tv.setTypeface(tv.typeface, Typeface.BOLD)
        tv.setTextColor(if (selected) t.onAccent else t.text)
        tv.background = rounded(if (selected) t.accent else t.action)
        tv.setOnClickListener { onClick() }
        return tv
    }

    private fun switchItem(title: String, checked: Boolean, onChanged: (Boolean) -> Unit): Switch {
        return Switch(this).apply {
            text = title
            setTextColor(t.text)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            isChecked = checked
            setOnCheckedChangeListener { _, c -> onChanged(c) }
            layoutParams = LinearLayout.LayoutParams(MATCH, dp(46))
        }
    }

    private fun inputField(hint: String, inputType: Int): EditText {
        return EditText(this).apply {
            this.hint = hint
            this.inputType = inputType
            setTextColor(t.text)
            setHintTextColor(t.muted)
            background = rounded(t.bg)
            setPadding(dp(12), dp(10), dp(12), dp(10))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14.5f)
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
        }
    }

    private fun fieldLp(): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(MATCH, dp(46)).apply { topMargin = dp(8) }

    private fun weighted(): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(0, dp(44), 1f).apply {
            topMargin = dp(6)
            marginStart = dp(3)
            marginEnd = dp(3)
        }
}
__ARABIKEY_EOF__

cat <<'__ARABIKEY_EOF__' > app/src/test/java/com/arabikey/keyboard/ArabiKeyUnitTests.kt
package com.arabikey.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ArabiKeyUnitTests {

    @Test
    fun compactLayoutHasBiggerFewerKeysPerRow() {
        val rows = Layouts.rows(Page.AR, "↵", arabicLayout = 0, numberRow = false)
        assertEquals(4, rows.size)
        assertEquals(10, rows[0].size)
        assertEquals(10, rows[1].size)
        assertEquals(8, rows[2].size)
    }

    @Test
    fun hugeLayoutHasMaxEightKeysPerRow() {
        val rows = Layouts.rows(Page.AR, "↵", arabicLayout = 1, numberRow = false)
        assertEquals(8, rows[0].size)
        assertEquals(8, rows[1].size)
        assertEquals(7, rows[2].size)
    }

    @Test
    fun numberRowPrependsDigitsWhenEnabled() {
        val rows = Layouts.rows(Page.AR, "↵", arabicLayout = 0, numberRow = true)
        assertEquals(5, rows.size)
        assertEquals("١", rows[0][0].label)
        assertEquals("٠", rows[0][9].label)
    }

    @Test
    fun missingArabicLettersAndLigaturesExist() {
        val mainLabels = Layouts.rows(Page.AR, "↵", arabicLayout = 0)
            .flatten()
            .flatMap { listOf(it.label, it.hint) + it.alts }
            .toSet()

        val shiftLabels = Layouts.rows(Page.AR_SHIFT, "↵")
            .flatten()
            .map { it.out }
            .toSet()

        val allAvailable = mainLabels + shiftLabels
        val required = listOf("أ", "إ", "آ", "ٱ", "ؤ", "ئ", "ء", "ة", "ى", "لا", "لأ", "لإ", "لآ", "پ", "چ", "ژ", "ڤ", "گ", "ذ", "ظ", "خ", "ث")
        for (ch in required) {
            assertTrue("Missing character: $ch", ch in allAvailable)
        }
    }

    @Test
    fun wordsSuggestionMatchesWithHamzaNormalization() {
        val defaults = Words.suggest("", "", arabic = true)
        assertEquals(3, defaults.size)

        val next = Words.suggest("", "السلام", arabic = true)
        assertTrue(next.contains("عليكم"))

        val hamzaMatch = Words.suggest("اهل", "", arabic = true)
        assertTrue(hamzaMatch.any { it.startsWith("أه") })
    }
}
__ARABIKEY_EOF__

echo "✅ اكتمل المشروع بالكامل (23 ملفاً) داخل: $PROJECT_DIR"