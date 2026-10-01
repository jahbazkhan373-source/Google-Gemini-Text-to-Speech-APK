require "import"
import "com.androlua.Http"
import "cjson"
import "com.androlua.LuaDialog"
import "android.widget.*"
import "android.view.*"
import "android.app.Dialog"
import "android.app.ProgressDialog"
import "android.text.InputType"
import "android.content.Context"
import "android.content.Intent"
import "android.net.Uri"
import "android.media.MediaPlayer"
import "android.media.PlaybackParams"
import "android.util.Base64"
import "android.os.*"
import "android.graphics.Typeface"
import "java.io.*"
import "java.net.URLEncoder"

local context = activity
local mainHandler = Handler(Looper.getMainLooper())

-- سٹوریج پرمیشنز کی درخواست
if Build.VERSION.SDK_INT >= 23 then
    activity.requestPermissions({"android.permission.WRITE_EXTERNAL_STORAGE", "android.permission.READ_EXTERNAL_STORAGE"}, 1)
end

-- بیک گراؤنڈ میں ایپ کو چلتا رکھنے کے لیے (WakeLock)
local wakeLock = nil
pcall(function()
    local powerManager = context.getSystemService(Context.POWER_SERVICE)
    wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GeminiTTS:WakeLock")
end)

pcall(function()
    Http.setConnTimeout(300000)
    Http.setReadTimeout(300000)
end)

local ALL_VOICES = {
    "Puck", "Kore", "Charon", "Zephyr", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe", "Autonoe", "Enceladus", "Iapetus",
    "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi", "Laomedeia", "Achernar", "Alnilam", "Schedar",
    "Gacrux", "Pulcherrima", "Capella", "Rigel", "Sirius", "Vega", "Altair", "Polaris"
}

local ALL_VOICES_LOWER = {}
for _, v in ipairs(ALL_VOICES) do ALL_VOICES_LOWER[string.lower(v)] = v end

local NARRATOR_VOICES = {"Orus (Male Narrator)", "Aoede (Female Narrator)"}

local FEMALE_MAPPING = {
    ["female 1"] = "Kore", ["female 2"] = "Zephyr", ["female 3"] = "Leda", ["female 4"] = "Callirrhoe",
    ["female 5"] = "Autonoe", ["female 6"] = "Algieba", ["female 7"] = "Despina", ["female 8"] = "Erinome",
    ["female 9"] = "Algenib", ["female 10"] = "Laomedeia", ["female 11"] = "Schedar", ["female 12"] = "Gacrux",
    ["female 13"] = "Pulcherrima", ["female 14"] = "Capella", ["female 15"] = "Vega"
}

local MALE_MAPPING = {
    ["male 1"] = "Puck", ["male 2"] = "Charon", ["male 3"] = "Fenrir", ["male 4"] = "Enceladus",
    ["male 5"] = "Iapetus", ["male 6"] = "Umbriel", ["male 7"] = "Rasalgethi", ["male 8"] = "Achernar",
    ["male 9"] = "Alnilam", ["male 10"] = "Rigel", ["male 11"] = "Sirius", ["male 12"] = "Altair",
    ["male 13"] = "Polaris"
}

local FEMALE_VOICES = {"Kore", "Zephyr", "Leda", "Callirrhoe", "Autonoe", "Algieba", "Despina", "Erinome", "Algenib", "Laomedeia", "Schedar", "Gacrux", "Pulcherrima", "Capella", "Vega"}
local MALE_VOICES = {"Puck", "Charon", "Fenrir", "Enceladus", "Iapetus", "Umbriel", "Rasalgethi", "Achernar", "Alnilam", "Rigel", "Sirius", "Altair", "Polaris"}

local TTS_MODELS = {"gemini-2.5-flash-preview-tts", "gemini-3.1-flash-tts-preview"}
local MAX_TOTAL_CHARS = 25000
local MIN_CHUNK_SIZE = 1500
local MAX_CHUNK_SIZE = 2000
local DELAY_BETWEEN_CHUNKS = 500

local selectedVoice = "Puck"
local selectedModel = TTS_MODELS[1]
local selectedNarrator = NARRATOR_VOICES[1]
local isStoryMode = false
local userText = ""
local userFileName = ""
local generatedAudioPath = nil
local mainMediaPlayer = nil
local isMainPlaying = false
local fileCounter = 0

local apiKeys = {"","","","","","","","","",""}
local currentKeyIndex = 1
local activeHttpRequest = nil
local cancellationRequested = false

local assignedVoices = {}
local dynMaleIndex = 1
local dynFemaleIndex = 1

local PREFS_NAME = "Google_Gemini_TTS_Prefs"
local prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

function getLibraryDir()
    local dir = File(context.getExternalFilesDir(nil).getPath() .. "/AudioLibrary")
    if not dir.exists() then dir.mkdirs() end
    return dir
end

function runOnUi(callback) mainHandler.post(Runnable({ run = callback })) end
function delay(ms, callback) Handler(Looper.getMainLooper()).postDelayed(Runnable({ run = callback }), ms) end
function showToast(msg) runOnUi(function() Toast.makeText(context, msg, Toast.LENGTH_SHORT).show() end) end
function speak(t) showToast(t) end

function setKeepAwake(keepAwake)
    pcall(function()
        if wakeLock then
            if keepAwake then
                if not wakeLock.isHeld() then wakeLock.acquire() end
            else
                if wakeLock.isHeld() then wakeLock.release() end
            end
        end
    end)
end

function copyFile(sourcePath, destPath)
    local success, err = pcall(function()
        local outFile = File(destPath)
        if not outFile.getParentFile().exists() then
            outFile.getParentFile().mkdirs()
        end
        local inStream = FileInputStream(File(sourcePath))
        local outStream = FileOutputStream(outFile)
        local buffer = byte[8192]
        while true do
            local len = inStream.read(buffer)
            if len == -1 then break end
            outStream.write(buffer, 0, len)
        end
        inStream.close()
        outStream.close()
    end)
    return success
end

-- APK میں کریش سے بچنے کے لیے LuaDialog استعمال کیا گیا ہے
function createOverlayDialog(view)
    local dialog = LuaDialog(activity)
    dialog.setView(view)
    return dialog
end

function showSuccessDialog(parentDialog, msgTextString)
    local layout = LinearLayout(context)
    layout.setOrientation(1)
    layout.setPadding(60, 60, 60, 60)
    layout.setGravity(Gravity.CENTER)
    local msgText = TextView(context)
    msgText.setText(msgTextString or "Action completed successfully!")
    msgText.setTextSize(16)
    msgText.setTextColor(0xFF4CAF50)
    msgText.setGravity(Gravity.CENTER)
    msgText.setPadding(0, 0, 0, 40)
    layout.addView(msgText)
    local btnOk = Button(context)
    btnOk.setText("OK")
    btnOk.setBackgroundColor(0xFF2196F3)
    btnOk.setTextColor(0xFFFFFFFF)
    layout.addView(btnOk)
    local successDialog = createOverlayDialog(layout)
    successDialog.show()
    btnOk.setOnClickListener(function()
        successDialog.dismiss()
        if parentDialog then parentDialog.dismiss() end
    end)
end

function showErrorDialog(errorMsg)
    local layout = LinearLayout(context)
    layout.setOrientation(1)
    layout.setPadding(60, 60, 60, 60)
    layout.setGravity(Gravity.CENTER)
    local msgText = TextView(context)
    msgText.setText("Error: " .. errorMsg)
    msgText.setTextSize(16)
    msgText.setTextColor(0xFFF44336)
    msgText.setGravity(Gravity.CENTER)
    msgText.setPadding(0, 0, 0, 40)
    layout.addView(msgText)
    local btnOk = Button(context)
    btnOk.setText("CLOSE")
    btnOk.setBackgroundColor(0xFF9E9E9E)
    btnOk.setTextColor(0xFFFFFFFF)
    layout.addView(btnOk)
    local errDialog = createOverlayDialog(layout)
    errDialog.show()
    btnOk.setOnClickListener(function() errDialog.dismiss() end)
end

function openFeedbackDialog()
    local scroll = ScrollView(context)
    local layout = LinearLayout(context)
    layout.setOrientation(1)
    layout.setPadding(40, 40, 40, 40)
    local title = TextView(context)
    title.setText("Send Feedback to Developer")
    title.setTextSize(20)
    title.setGravity(Gravity.CENTER)
    title.setTextColor(0xFF2196F3)
    title.setPadding(0, 0, 0, 20)
    title.setTypeface(Typeface.DEFAULT_BOLD)
    layout.addView(title)
    
    local editAppName = EditText(context)
    editAppName.setText("Google Gemini Text to Speech")
    editAppName.setEnabled(false)
    editAppName.setTextColor(0xFF888888)
    layout.addView(editAppName)
    
    local editName = EditText(context)
    editName.setHint("Enter Name")
    layout.addView(editName)
    
    local editWa = EditText(context)
    editWa.setHint("WhatsApp Number (Optional)")
    editWa.setInputType(InputType.TYPE_CLASS_PHONE)
    layout.addView(editWa)
    
    local editMsg = EditText(context)
    editMsg.setHint("Enter Feedback Message")
    layout.addView(editMsg)
    
    local btnSend = Button(context)
    btnSend.setText("SEND FEEDBACK")
    btnSend.setBackgroundColor(0xFF2196F3)
    btnSend.setTextColor(0xFFFFFFFF)
    local pSend = LinearLayout.LayoutParams(-1, -2)
    pSend.topMargin = 15
    btnSend.setLayoutParams(pSend)
    layout.addView(btnSend)
    
    local btnBack = Button(context)
    btnBack.setText("GO BACK")
    btnBack.setBackgroundColor(0xFFF44336)
    btnBack.setTextColor(0xFFFFFFFF)
    local pBack = LinearLayout.LayoutParams(-1, -2)
    pBack.topMargin = 10
    btnBack.setLayoutParams(pBack)
    layout.addView(btnBack)
    
    scroll.addView(layout)
    local fbDialog = createOverlayDialog(scroll)
    fbDialog.show()
    btnBack.setOnClickListener(function() fbDialog.dismiss() end)
    
    btnSend.setOnClickListener(function()
        local name = tostring(editName.getText() or "")
        local wa = tostring(editWa.getText() or "")
        local msg = tostring(editMsg.getText() or "")
        if msg == "" then speak("Please enter feedback message") return end
        if #msg > 5000 then speak("Feedback exceeds 5000 characters") return end
        local pd = ProgressDialog(context)
        pd.setMessage("Sending please wait...")
        pd.setCancelable(false)
        pd.show()
        speak("Sending please wait")
        local BOT_TOKEN = "8779947243:AAEC3HYql5KbbJnJZTe7YYB2rIQK-xoJab8"
        local CHAT_ID = "7390973466"
        local VERCEL_URL = "https://send-feedback-dusky.vercel.app/api"
        local formattedName = (name ~= "" and name or "Anonymous")
        local fullText = "New Feedback Received:\nApp: Google Gemini Text to Speech\nName: " .. formattedName
        if wa ~= "" then fullText = fullText .. "\nWhatsApp: " .. wa end
        fullText = fullText .. "\nFeedback: " .. msg
        local encodedToken = URLEncoder.encode(BOT_TOKEN, "UTF-8")
        local encodedChatId = URLEncoder.encode(CHAT_ID, "UTF-8")
        local encodedText = URLEncoder.encode(fullText, "UTF-8")
        local postData = "bot_token=" .. encodedToken .. "&chat_id=" .. encodedChatId .. "&text=" .. encodedText
        Http.post(VERCEL_URL, postData, function(code, content)
            pcall(function() pd.dismiss() end)
            if tonumber(code) == 200 then
                speak("Feedback sent successfully")
                editMsg.setText("")
                showSuccessDialog(fbDialog, "Feedback sent successfully!")
            else
                local errCode = tostring(code or "Unknown")
                speak("Failed to send.")
                showErrorDialog("Error Code: " .. errCode .. "\nDetails: " .. tostring(content))
            end
        end)
    end)
end

function saveSettings()
    local editor = prefs.edit()
    editor.putString("voice", selectedVoice)
    editor.putString("model", selectedModel)
    editor.putString("narrator", selectedNarrator)
    editor.putBoolean("storyMode", isStoryMode)
    for i=1, 10 do editor.putString("apikey_"..i, apiKeys[i]) end
    editor.putString("filename", userFileName)
    editor.putInt("fileCounter", fileCounter)
    editor.apply()
end

function loadSettings()
    selectedVoice = prefs.getString("voice", "Puck")
    selectedModel = prefs.getString("model", TTS_MODELS[1])
    selectedNarrator = prefs.getString("narrator", NARRATOR_VOICES[1])
    isStoryMode = prefs.getBoolean("storyMode", false)
    for i=1, 10 do apiKeys[i] = prefs.getString("apikey_"..i, "") end
    userFileName = prefs.getString("filename", "")
    fileCounter = prefs.getInt("fileCounter", 0)
end

function getDefaultFileName()
    fileCounter = fileCounter + 1
    saveSettings()
    return "Jahbaz_" .. string.format("%03d", fileCounter)
end

function initMainMediaPlayer()
    if mainMediaPlayer ~= nil then
        if isMainPlaying then pcall(function() mainMediaPlayer.stop() end) isMainPlaying = false end
        pcall(function() mainMediaPlayer.release() end)
    end
    mainMediaPlayer = MediaPlayer()
end

function toggleMainPlayPause(playBtn)
    if mainMediaPlayer == nil then showToast("No audio loaded") return false end
    if isMainPlaying then 
        pcall(function() mainMediaPlayer.pause() end) 
        isMainPlaying = false 
        runOnUi(function() playBtn.setText("PLAY") end)
    else 
        pcall(function() mainMediaPlayer.start() end) 
        isMainPlaying = true 
        runOnUi(function() playBtn.setText("PAUSE") end) 
    end
end

function writeWavHeader(outStream, totalAudioLen)
    local sampleRate, channels, bitsPerSample = 24000, 1, 16
    local byteRate = sampleRate * channels * (bitsPerSample / 8)
    local blockAlign = channels * (bitsPerSample / 8)
    local totalSize = totalAudioLen + 36
    local function getBytes(val) return {val & 0xff, (val >> 8) & 0xff, (val >> 16) & 0xff, (val >> 24) & 0xff} end
    local totalSizeB, sampleRateB, byteRateB, dataLenB = getBytes(totalSize), getBytes(sampleRate), getBytes(byteRate), getBytes(totalAudioLen)
    local header = {0x52, 0x49, 0x46, 0x46, totalSizeB[1], totalSizeB[2], totalSizeB[3], totalSizeB[4], 0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00, 0x01, 0x00, channels & 0xff, (channels >> 8) & 0xff, sampleRateB[1], sampleRateB[2], sampleRateB[3], sampleRateB[4], byteRateB[1], byteRateB[2], byteRateB[3], byteRateB[4], blockAlign & 0xff, (blockAlign >> 8) & 0xff, bitsPerSample & 0xff, (bitsPerSample >> 8) & 0xff, 0x64, 0x61, 0x74, 0x61, dataLenB[1], dataLenB[2], dataLenB[3], dataLenB[4]}
    for i = 1, #header do outStream.write(header[i]) end
end

function getWorkingApiKey()
    for i=1, 10 do
        local idx = ((currentKeyIndex + i - 2) % 10) + 1
        if apiKeys[idx] and apiKeys[idx] ~= "" then currentKeyIndex = idx return apiKeys[idx] end
    end
    return nil
end

function applySSML(dialogue)
    local prosodyOpen = ""
    local prosodyClose = ""
    local dLower = string.lower(dialogue)
    if dLower:find("%[laughing%]") or dialogue:find("%[ہنستے ہوئے%]") or dialogue:find("%[خوشی سے%]") or dLower:find("%[happy%]") then
        prosodyOpen = '<prosody rate="fast" pitch="high">'
        prosodyClose = '</prosody>'
    elseif dLower:find("%[sad%]") or dialogue:find("%[روتے ہوئے%]") or dialogue:find("%[اداس%]") then
        prosodyOpen = '<prosody rate="slow" pitch="low">'
        prosodyClose = '</prosody>'
    elseif dLower:find("%[angry%]") or dialogue:find("%[غصے سے%]") then
        prosodyOpen = '<prosody rate="fast" pitch="high">'
        prosodyClose = '</prosody>'
    elseif dLower:find("%[serious%]") or dialogue:find("%[سنجیدہ%]") then
        prosodyOpen = '<prosody rate="slow" pitch="medium">'
        prosodyClose = '</prosody>'
    end
    local cleaned = dialogue:gsub("%[[^%]]+%]", "")
    cleaned = cleaned:gsub("%*(.-)%*", '<emphasis level="strong">%1</emphasis>')
    cleaned = cleaned:gsub("%[pause:(.-)%]", '<break time="%1"/>')
    if prosodyOpen ~= "" then return "<speak>" .. prosodyOpen .. cleaned .. prosodyClose .. "</speak>" else return cleaned end
end

function parseStoryLine(line)
    local voiceTag = ""
    local charName = ""
    local dialogue = line
    
    local tagMatch, nameMatch, restOfLine = line:match("^%s*%[([^%]]+)%]%s*(.-):%s*(.*)")
    if tagMatch then
        voiceTag = string.lower(tagMatch:match("^%s*(.-)%s*$") or "")
        charName = string.lower(nameMatch:match("^%s*(.-)%s*$") or "")
        dialogue = restOfLine
    else
        tagMatch, restOfLine = line:match("^%s*%[([^%]]+)%]%s*(.*)")
        if tagMatch then
            voiceTag = string.lower(tagMatch:match("^%s*(.-)%s*$") or "")
            dialogue = restOfLine
        else
            nameMatch, restOfLine = line:match("^%s*(.-):%s*(.*)")
            if nameMatch and #nameMatch < 50 and not nameMatch:match("%[") then
                charName = string.lower(nameMatch:match("^%s*(.-)%s*$") or "")
                dialogue = restOfLine
            end
        end
    end
    
    dialogue = dialogue:gsub("%[[^%]]+%]", "")
    dialogue = dialogue:match("^%s*(.-)%s*$")
    local voiceToUse = selectedNarrator:match("^(%w+)")
    
    if voiceTag ~= "" then
        local normalizedTag = voiceTag:gsub("one", "1"):gsub("two", "2"):gsub("three", "3"):gsub("four", "4"):gsub("five", "5"):gsub("six", "6"):gsub("seven", "7"):gsub("eight", "8"):gsub("nine", "9"):gsub("ten", "10"):gsub("eleven", "11"):gsub("twelve", "12"):gsub("thirteen", "13"):gsub("fourteen", "14"):gsub("fifteen", "15"):gsub(" voice", "")
        normalizedTag = normalizedTag:match("^%s*(.-)%s*$")
        
        if FEMALE_MAPPING[normalizedTag] then
            voiceToUse = FEMALE_MAPPING[normalizedTag]
        elseif MALE_MAPPING[normalizedTag] then
            voiceToUse = MALE_MAPPING[normalizedTag]
        elseif ALL_VOICES_LOWER[normalizedTag] then
            voiceToUse = ALL_VOICES_LOWER[normalizedTag]
        elseif assignedVoices[normalizedTag] then
            voiceToUse = assignedVoices[normalizedTag]
        else
            local isFem = normalizedTag:find("female") or normalizedTag:find("عورت") or normalizedTag:find("فیمیل")
            local isMal = normalizedTag:find("male") or normalizedTag:find("مرد") or normalizedTag:find("میل")
            if isFem then
                voiceToUse = FEMALE_VOICES[dynFemaleIndex] or FEMALE_VOICES[1]
                dynFemaleIndex = (dynFemaleIndex % #FEMALE_VOICES) + 1
            elseif isMal then
                voiceToUse = MALE_VOICES[dynMaleIndex] or MALE_VOICES[1]
                dynMaleIndex = (dynMaleIndex % #MALE_VOICES) + 1
            elseif normalizedTag:find("narrator") or normalizedTag:find("راوی") then
                voiceToUse = selectedNarrator:match("^(%w+)")
            else
                voiceToUse = MALE_VOICES[dynMaleIndex] or MALE_VOICES[1]
                dynMaleIndex = (dynMaleIndex % #MALE_VOICES) + 1
            end
            assignedVoices[normalizedTag] = voiceToUse
        end
        if charName ~= "" then assignedVoices[charName] = voiceToUse end
    elseif charName ~= "" and assignedVoices[charName] then
        voiceToUse = assignedVoices[charName]
    end
    return voiceToUse, applySSML(dialogue)
end

function splitTextIntoSmartChunks(text, isStory)
    local chunks = {}
    if text == nil or text == "" then return chunks end
    text = text:gsub("\r", ""):gsub("[%z\1-\8\11-\31\127]", "")
    if #text > MAX_TOTAL_CHARS then text = text:sub(1, MAX_TOTAL_CHARS) end
    if isStory then
        for line in text:gmatch("([^\n]+)") do table.insert(chunks, line) end
    else
        local i = 1
        local len = #text
        while i <= len do
            if (len - i) < MAX_CHUNK_SIZE then
                table.insert(chunks, text:sub(i, len))
                break
            else
                local searchArea = text:sub(i, i + MAX_CHUNK_SIZE)
                local lastBreak = searchArea:match(".*()[.!?\n]") 
                local splitPos = i + MAX_CHUNK_SIZE
                if lastBreak and lastBreak > (MIN_CHUNK_SIZE / 2) then
                    splitPos = i + lastBreak - 1
                end
                table.insert(chunks, text:sub(i, splitPos))
                i = splitPos + 1
            end
        end
    end
    return chunks
end

function textToSpeech(text, voice, modelIndex, retryCount, callback)
    if modelIndex > #TTS_MODELS then runOnUi(function() callback(false, nil, "All models failed") end) return end
    local apikey = getWorkingApiKey()
    if not apikey then runOnUi(function() callback(false, nil, "No API Keys found") end) return end
    
    local currentModel = TTS_MODELS[modelIndex]
    local apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/" .. currentModel .. ":generateContent?key=" .. apikey
    local requestBody = {contents = {{parts = {{text = text}}}}, generationConfig = {responseModalities = {"AUDIO"}, speechConfig = {voiceConfig = {prebuiltVoiceConfig = {voiceName = voice}}}}}
    local headers = HashMap() headers.put("Content-Type", "application/json")

    activeHttpRequest = Http.post(apiUrl, cjson.encode(requestBody), headers, function(code, content)
        activeHttpRequest = nil
        if cancellationRequested then runOnUi(function() callback(false, nil, "Cancelled") end) return end
        if code == 200 then
            local ok, data = pcall(cjson.decode, content)
            if ok and data and data.candidates and #data.candidates > 0 then
                local candidate = data.candidates[1]
                if candidate.content and candidate.content.parts then
                    for i = 1, #candidate.content.parts do
                        local part = candidate.content.parts[i]
                        if part.inlineData and part.inlineData.data then
                            local audioBytes = Base64.decode(part.inlineData.data, Base64.NO_WRAP)
                            if #audioBytes > 44 then runOnUi(function() callback(true, audioBytes, currentModel) end) return end
                        end
                    end
                end
            end
            textToSpeech(text, voice, modelIndex + 1, 0, callback)
        elseif code == 429 or code == 403 or code == 500 then
            if retryCount < 10 then
                currentKeyIndex = (currentKeyIndex % 10) + 1
                delay(1000, function() textToSpeech(text, voice, modelIndex, retryCount + 1, callback) end)
            else
                if modelIndex < #TTS_MODELS then textToSpeech(text, voice, modelIndex + 1, 0, callback)
                else runOnUi(function() callback(false, nil, "Rate limit exceeded on all keys") end) end
            end
        else
            if modelIndex < #TTS_MODELS then textToSpeech(text, voice, modelIndex + 1, 0, callback)
            else runOnUi(function() callback(false, nil, "HTTP " .. code) end) end
        end
    end)
end

function generateFullAudio(text, modeOn, generateBtn, playBtn, resultLayout, statusText, stopBtn)
    cancellationRequested = false
    assignedVoices = {} dynMaleIndex = 1 dynFemaleIndex = 1
    local chunks = splitTextIntoSmartChunks(text, modeOn)
    local totalChunks = #chunks
    local completedChunks = 0
    local isFinalized = false

    if totalChunks == 0 then
        runOnUi(function() generateBtn.setEnabled(true) generateBtn.setText("GENERATE AUDIO") showToast("No text to generate") end) return
    end
    setKeepAwake(true)

    local tempPath = context.getExternalFilesDir(nil).getPath() .. "/tts_temp_" .. os.time() .. ".wav"
    local tempFile = File(tempPath)
    local fos = FileOutputStream(tempFile)
    local totalAudioLen = 0
    writeWavHeader(fos, 0)
    
    local baseName = userFileName ~= "" and userFileName or getDefaultFileName()
    local finalPath = getLibraryDir().getPath() .. "/" .. baseName .. ".wav"

    local function finalizeAudio(isPartial)
        if isFinalized then return end
        isFinalized = true
        setKeepAwake(false)
        pcall(function() fos.close() end)
        
        if totalAudioLen == 0 then
            runOnUi(function() generateBtn.setEnabled(true) generateBtn.setText("GENERATE AUDIO") stopBtn.setEnabled(false) end)
            pcall(function() tempFile.delete() end) return
        end

        local actualFinalPath = finalPath
        if isPartial then
            actualFinalPath = getLibraryDir().getPath() .. "/PARTIAL_" .. baseName .. ".wav"
        end

        local finalFos = FileOutputStream(File(actualFinalPath))
        writeWavHeader(finalFos, totalAudioLen)
        local tempInput = FileInputStream(tempFile)
        tempInput.skip(44)
        local buffer = byte[8192]
        while true do
            local len = tempInput.read(buffer)
            if len == -1 then break end
            finalFos.write(buffer, 0, len)
        end
        pcall(function() tempInput.close() finalFos.close() tempFile.delete() end)
        generatedAudioPath = actualFinalPath

        runOnUi(function()
            resultLayout.setVisibility(View.VISIBLE)
            initMainMediaPlayer()
            pcall(function() 
                mainMediaPlayer.setDataSource(generatedAudioPath) 
                mainMediaPlayer.prepare() 
                mainMediaPlayer.setOnCompletionListener(MediaPlayer.OnCompletionListener{
                    onCompletion = function(mp)
                        isMainPlaying = false
                        runOnUi(function() playBtn.setText("PLAY") end)
                    end
                })
            end)
            playBtn.setEnabled(true) generateBtn.setEnabled(true) generateBtn.setText("REGENERATE")
            statusText.setText("Status: " .. completedChunks .. " parts completed.")
            stopBtn.setEnabled(false)
            showToast("Audio Auto-Saved to Library!")
        end)
    end

    local function processNextChunk(index)
        if cancellationRequested then 
            runOnUi(function() statusText.setText("Saving Partial Audio to Library...") end)
            finalizeAudio(true) return 
        end
        if index > totalChunks then finalizeAudio(false) return end

        runOnUi(function() statusText.setText("Generating part " .. index .. " of " .. totalChunks) end)
        
        local currentVoice = selectedVoice
        local currentText = chunks[index]
        if modeOn then currentVoice, currentText = parseStoryLine(currentText) else currentText = applySSML(currentText) end

        if currentText == nil or currentText == "" or currentText == "<speak></speak>" then
            processNextChunk(index + 1)
            return
        end

        textToSpeech(currentText, currentVoice, 1, 0, function(success, audioBytes, usedModel)
            if cancellationRequested or not success then
                finalizeAudio(true) return
            end
            fos.write(audioBytes)
            totalAudioLen = totalAudioLen + #audioBytes
            completedChunks = completedChunks + 1
            runOnUi(function() statusText.setText("Part " .. completedChunks .. " / " .. totalChunks .. " done") end)
            delay(DELAY_BETWEEN_CHUNKS, function() processNextChunk(index + 1) end)
        end)
    end
    processNextChunk(1)
end

function formatTime(ms)
    local ts = math.floor(ms / 1000)
    return string.format("%02d:%02d", math.floor(ts / 60), ts % 60)
end

-- ایڈوانسڈ پلیئر ڈائیلاگ
function openAdvancedPlayer(filePath, fileName)
    local p = MediaPlayer()
    p.setDataSource(filePath)
    p.prepare()
    local duration = p.getDuration()
    local currentSpeed = 1.0
    local isPl = false
    local uiHandler = Handler(Looper.getMainLooper())
    local updater = nil
    local views = {}
    local layout = {
        LinearLayout, orientation="vertical", padding="20dp", layout_width="fill", layout_height="wrap", backgroundColor="#FFFFFF",
        { TextView, text=fileName, textSize=16, textColor="#333333", gravity="center", paddingBottom="10dp", typeface=Typeface.DEFAULT_BOLD },
        { TextView, id="timeTxt", text="00:00 / " .. formatTime(duration), textSize=14, textColor="#666666", gravity="center", paddingBottom="10dp" },
        { SeekBar, id="seekBar", layout_width="fill", max=duration, paddingBottom="20dp" },
        { LinearLayout, orientation="horizontal", gravity="center", layout_width="fill", layout_marginBottom="20dp",
            { Button, text="-10s", backgroundColor="#9E9E9E", textColor="#FFFFFF", layout_marginRight="10dp", onClick=function() 
                local nw = p.getCurrentPosition() - 10000; if nw < 0 then nw = 0 end; p.seekTo(nw) 
            end},
            { Button, id="btnPlay", text="PLAY", backgroundColor="#4CAF50", textColor="#FFFFFF", padding="15dp", textSize=16 },
            { Button, text="+10s", backgroundColor="#9E9E9E", textColor="#FFFFFF", layout_marginLeft="10dp", onClick=function() 
                local nw = p.getCurrentPosition() + 10000; if nw > duration then nw = duration end; p.seekTo(nw) 
            end}
        },
        { LinearLayout, orientation="horizontal", gravity="center", layout_width="fill",
            { Button, text="Slower", backgroundColor="#2196F3", textColor="#FFFFFF", onClick=function() 
                currentSpeed = math.max(0.5, currentSpeed - 0.25)
                pcall(function() local pm = p.getPlaybackParams(); pm.setSpeed(currentSpeed); p.setPlaybackParams(pm) end)
                views.speedTxt.setText(string.format("Speed: %.2fx", currentSpeed))
            end},
            { TextView, id="speedTxt", text="Speed: 1.00x", textColor="#333333", padding="10dp", textSize=14 },
            { Button, text="Faster", backgroundColor="#FF9800", textColor="#FFFFFF", onClick=function() 
                currentSpeed = math.min(2.0, currentSpeed + 0.25)
                pcall(function() local pm = p.getPlaybackParams(); pm.setSpeed(currentSpeed); p.setPlaybackParams(pm) end)
                views.speedTxt.setText(string.format("Speed: %.2fx", currentSpeed))
            end}
        },
        { Button, id="btnClose", text="CLOSE", layout_width="fill", backgroundColor="#9E9E9E", textColor="#FFFFFF", layout_marginTop="15dp" }
    }
    local dlg = LuaDialog(activity)
    dlg.setView(loadlayout(layout, views))
    
    updater = Runnable({
        run = function()
            if p and isPl then
                local pos = p.getCurrentPosition()
                views.seekBar.setProgress(pos)
                views.timeTxt.setText(formatTime(pos) .. " / " .. formatTime(duration))
                uiHandler.postDelayed(updater, 500)
            end
        end
    })
    views.btnPlay.onClick = function()
        if isPl then p.pause(); views.btnPlay.setText("PLAY"); isPl = false 
        else p.start(); views.btnPlay.setText("PAUSE"); isPl = true; uiHandler.post(updater) end
    end
    views.seekBar.setOnSeekBarChangeListener({
        onProgressChanged = function(sb, prog, fromUser) if fromUser then p.seekTo(prog) views.timeTxt.setText(formatTime(prog) .. " / " .. formatTime(duration)) end end,
        onStartTrackingTouch = function() end, onStopTrackingTouch = function() end
    })
    p.setOnCompletionListener({ onCompletion = function() isPl = false views.btnPlay.setText("PLAY") views.seekBar.setProgress(duration) end })
    views.btnClose.onClick = function() isPl=false pcall(function() p.stop(); p.release() end) dlg.dismiss() end
    dlg.show()
end

-- آڈیو لائبریری ڈائیلاگ
function showAudioLibrary()
    local dir = getLibraryDir()
    local views = {}
    local listLayout = { LinearLayout, orientation="vertical", padding="10dp", layout_width="fill", layout_height="wrap"}
    
    local hasFiles = false
    pcall(function()
        local files = dir.listFiles()
        if files then
            local count = tonumber(files.length) or 0
            for i = 0, count - 1 do
                pcall(function()
                    local file = files[i]
                    if file and file.getName():match("%.wav$") then
                        hasFiles = true
                        table.insert(listLayout, {
                            LinearLayout, orientation="horizontal", padding="10dp", layout_width="fill", backgroundColor="#F0F0F0", layout_marginBottom="5dp",
                            { TextView, text=file.getName(), layout_weight="1", textColor="#333333", gravity="center_vertical" },
                            { Button, text="PLAY", backgroundColor="#4CAF50", textColor="#FFFFFF", padding="5dp", textSize=11, onClick=function() 
                                openAdvancedPlayer(file.getAbsolutePath(), file.getName())
                            end},
                            { Button, text="DOWNLOAD", backgroundColor="#FF9800", textColor="#FFFFFF", padding="5dp", textSize=11, layout_marginLeft="5dp", onClick=function()
                                local dest = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).getPath() .. "/" .. file.getName()
                                local success = copyFile(file.getAbsolutePath(), dest)
                                if success then showToast("Saved to Downloads Folder!") else showToast("Failed to Download") end
                            end},
                            { Button, text="DEL", backgroundColor="#F44336", textColor="#FFFFFF", padding="5dp", textSize=11, layout_marginLeft="5dp", onClick=function()
                                file.delete() showToast("Deleted") dlg.dismiss() showAudioLibrary()
                            end}
                        })
                    end
                end)
            end
        end
    end)
    
    if not hasFiles then table.insert(listLayout, {TextView, text="No saved audio files found.", gravity="center", padding="20dp"}) end
    table.insert(listLayout, {Button, id="btnClose", text="CLOSE", layout_width="fill", backgroundColor="#9E9E9E", textColor="#FFFFFF", layout_marginTop="10dp"})
    
    local scroll = { ScrollView, layout_width="fill", layout_height="fill", listLayout }
    local dlg = LuaDialog(activity) 
    dlg.setTitle("Audio Library") 
    dlg.setView(loadlayout(scroll, views))
    views.btnClose.onClick = function() dlg.dismiss() end
    dlg.show()
end

-- مور آپشنز ڈائیلاگ
function showMoreOptions()
    local views = {}
    local layout = {
        LinearLayout, orientation="vertical", padding="20dp", layout_width="fill", layout_height="wrap",
        {Button, id="btnLibrary", text="Audio Library", layout_width="fill", backgroundColor="#4CAF50", textColor="#FFFFFF", layout_marginBottom="10dp"},
        {Button, id="btnFeedback", text="Feedback", layout_width="fill", backgroundColor="#9C27B0", textColor="#FFFFFF", layout_marginBottom="10dp"},
        {Button, id="btnWhatsapp", text="Contact Developer", layout_width="fill", backgroundColor="#25D366", textColor="#FFFFFF", layout_marginBottom="10dp"},
        {Button, id="btnChannel", text="WhatsApp Channel", layout_width="fill", backgroundColor="#075E54", textColor="#FFFFFF", layout_marginBottom="10dp"},
        {Button, id="btnAbout", text="About & Support", layout_width="fill", backgroundColor="#2196F3", textColor="#FFFFFF", layout_marginBottom="15dp"},
        {Button, id="btnClose", text="CLOSE", layout_width="fill", backgroundColor="#9E9E9E", textColor="#FFFFFF"}
    }
    local dlg = LuaDialog(activity) 
    dlg.setTitle("More Options") 
    dlg.setView(loadlayout(layout, views))
    
    views.btnLibrary.onClick = function() showAudioLibrary() end
    views.btnFeedback.onClick = function() openFeedbackDialog() end
    
    views.btnWhatsapp.onClick = function()
        pcall(function()
            local intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://wa.me/923041011727"))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            dlg.dismiss()
        end)
    end
    
    views.btnChannel.onClick = function()
        pcall(function()
            local intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://whatsapp.com/channel/0029Vb5y8QCEwEk1OkHev10x"))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            dlg.dismiss()
        end)
    end
    
    views.btnAbout.onClick = function() showToast("Google Gemini Text to Speech\nDeveloper: Jahbaz Hijbani") end
    views.btnClose.onClick = function() dlg.dismiss() end
    
    dlg.show()
end

-- اے پی آئی سیٹنگز ڈائیلاگ
function showApiSettings()
    local views = {}
    local layout = { ScrollView, layout_width="fill", layout_height="fill", { LinearLayout, orientation="vertical", padding="15dp", layout_width="fill", layout_height="wrap", { TextView, text="10 API KEYS SETUP", textSize=16, textColor="#2196F3", gravity="center", paddingBottom="10dp", typeface=Typeface.DEFAULT_BOLD } } }
    local keysLayout = layout[2]
    
    for i=1, 10 do
        table.insert(keysLayout, {TextView, text="API Key " .. i .. ":", textSize=11, paddingBottom="2dp", paddingTop="3dp"})
        table.insert(keysLayout, {
            LinearLayout, orientation="horizontal", layout_width="fill", layout_marginBottom="2dp",
            {EditText, id="apiKey"..i, text=apiKeys[i], hint="Enter Key "..i, layout_weight="1", backgroundColor="#F5F5F5", padding="8dp", textSize=12},
            {Button, id="testBtn"..i, text="TEST", backgroundColor="#FF9800", textColor="#FFFFFF", padding="8dp", textSize=11, layout_marginLeft="5dp"}
        })
    end
    table.insert(keysLayout, { LinearLayout, orientation="horizontal", layout_width="fill", layout_marginTop="10dp", {Button, id="saveBtn", text="SAVE ALL", layout_weight="1", backgroundColor="#4CAF50", textColor="#FFFFFF", padding="10dp"}, {Button, id="closeBtn", text="CLOSE", layout_weight="1", backgroundColor="#9E9E9E", textColor="#FFFFFF", padding="10dp", layout_marginLeft="10dp"} })
    
    local dlg = LuaDialog(activity) 
    dlg.setTitle("API Configuration") 
    dlg.setView(loadlayout(layout, views))
    
    for i=1, 10 do
        views["testBtn"..i].onClick = function()
            local key = views["apiKey"..i].getText().toString()
            if key == "" then showToast("Please enter API key "..i.." first") return end
            
            local testUrl = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent?key=" .. key
            local testBody = {contents = {{parts = {{text = "test"}}}}, generationConfig = {responseModalities = {"AUDIO"}, speechConfig = {voiceConfig = {prebuiltVoiceConfig = {voiceName = "Puck"}}}}}
            local hdrs = HashMap() hdrs.put("Content-Type", "application/json")
            
            local pd = ProgressDialog(context)
            pd.setMessage("Testing Key " .. i .. "...")
            pd.setCancelable(false)
            pd.show()
            
            Http.post(testUrl, cjson.encode(testBody), hdrs, function(code, content)
                runOnUi(function()
                    pcall(function() pd.dismiss() end)
                    if code == 200 then
                        showSuccessDialog(nil, "✓ Key " .. i .. " is Valid! TTS working.")
                    elseif code == 429 then
                        showErrorDialog("Key " .. i .. " valid, but Rate Limit reached (429).")
                    else
                        showErrorDialog("Key " .. i .. " failed.\nCode: " .. code .. "\nResponse: " .. tostring(content))
                    end
                end)
            end)
        end
    end
    
    views.saveBtn.onClick = function() for i=1, 10 do apiKeys[i] = views["apiKey"..i].getText().toString() end saveSettings() showToast("Keys Saved!") dlg.dismiss() end
    views.closeBtn.onClick = function() dlg.dismiss() end
    dlg.show()
end

-- مین انٹرفیس (Activity)
function showMain()
    loadSettings() initMainMediaPlayer()
    local views = {}

    local scrollLayout = {
        ScrollView, layout_width="fill", layout_height="fill",
        {
            LinearLayout, orientation="vertical", padding="15dp", layout_width="fill", layout_height="wrap",
            {TextView, text="Google Gemini Text to Speech", textSize=20, textColor="#1B5E20", gravity="center", paddingBottom="4dp", typeface=Typeface.DEFAULT_BOLD},
            {TextView, text="Developer: Jahbaz Hijbani", textSize=12, textColor="#999999", gravity="center", paddingBottom="10dp"},
            
            {Button, id="optBtn", text="More Options", layout_width="fill", backgroundColor="#607D8B", textColor="#FFFFFF", padding="10dp", layout_marginBottom="10dp"},
            
            {Switch, id="storyModeSwitch", text=" Story Mode (Multi-Voice) ", checked=isStoryMode, textColor="#D32F2F", textSize=15, layout_marginBottom="8dp", typeface=Typeface.DEFAULT_BOLD},
            
            {EditText, id="textInput", hint="Type text here... Max 25,000 chars", layout_width="fill", layout_height="140dp", backgroundColor="#F5F5F5", padding="10dp", gravity=Gravity.TOP, textSize=13, layout_marginBottom="4dp"},
            {TextView, id="charCountText", text="Characters: 0 / " .. MAX_TOTAL_CHARS, textSize=10, textColor="#666666", gravity="right", paddingBottom="8dp"},
            
            {LinearLayout, id="singleModeLayout", orientation="horizontal", layout_width="fill", visibility=isStoryMode and View.GONE or View.VISIBLE, layout_marginBottom="8dp",
                {LinearLayout, orientation="vertical", layout_weight="1", layout_marginRight="4dp",
                    {TextView, text="Voice:", textSize=12, paddingBottom="2dp"},
                    {Spinner, id="voiceSpin", layout_width="fill", backgroundColor="#F5F5F5"},
                },
                {LinearLayout, orientation="vertical", layout_weight="1", layout_marginLeft="4dp",
                    {TextView, text="Model:", textSize=12, paddingBottom="2dp"},
                    {Spinner, id="modelSpinSingle", layout_width="fill", backgroundColor="#F5F5F5"},
                }
            },
            
            {LinearLayout, id="storyModeLayout", orientation="vertical", layout_width="fill", visibility=isStoryMode and View.VISIBLE or View.GONE,
                {LinearLayout, orientation="horizontal", layout_width="fill", layout_marginBottom="8dp",
                    {LinearLayout, orientation="vertical", layout_weight="1", layout_marginRight="4dp",
                        {TextView, text="Narrator Voice:", textSize=12, textColor="#1B5E20", paddingBottom="2dp"},
                        {Spinner, id="narratorSpin", layout_width="fill", backgroundColor="#E8F5E9"},
                    },
                    {LinearLayout, orientation="vertical", layout_weight="1", layout_marginLeft="4dp",
                        {TextView, text="Model:", textSize=12, paddingBottom="2dp"},
                        {Spinner, id="modelSpinStory", layout_width="fill", backgroundColor="#F5F5F5"},
                    }
                },
            },

            {EditText, id="fileNameInput", hint="File name (Optional)", text=userFileName, layout_width="fill", backgroundColor="#F5F5F5", padding="8dp", layout_marginBottom="8dp"},
            {TextView, id="statusText", text="", textSize=11, textColor="#FF5722", gravity="center", paddingBottom="8dp"},
            
            {Button, id="generateBtn", text="GENERATE AUDIO", layout_width="fill", backgroundColor="#2196F3", textColor="#FFFFFF", padding="12dp", textSize=15, typeface=Typeface.DEFAULT_BOLD, layout_marginBottom="8dp"},
            
            {LinearLayout, id="resultLayout", orientation="horizontal", layout_width="fill", visibility=View.GONE, layout_marginBottom="8dp",
                {Button, id="playBtn", text="PLAY", layout_weight="1", backgroundColor="#4CAF50", textColor="#FFFFFF", padding="10dp", textSize=11},
                {Button, id="downloadBtn", text="DOWNLOAD", layout_weight="1", backgroundColor="#FF9800", textColor="#FFFFFF", padding="10dp", textSize=11, layout_marginLeft="4dp"}
            },
            
            {LinearLayout, orientation="horizontal", layout_width="fill", layout_marginTop="4dp",
                {Button, id="apiBtn", text="API KEYS", layout_weight="1", backgroundColor="#9C27B0", textColor="#FFFFFF", padding="10dp", textSize=11},
                {Button, id="stopBtn", text="STOP", layout_weight="1", backgroundColor="#F44336", textColor="#FFFFFF", padding="10dp", textSize=11, enabled=false, layout_marginLeft="4dp"}
            }
        }
    }

    activity.setTitle("Google Gemini Text to Speech")
    activity.setContentView(loadlayout(scrollLayout, views))

    pcall(function()
        activity.getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
    end)

    views.storyModeSwitch.setOnCheckedChangeListener({
        onCheckedChanged=function(view, isChecked)
            isStoryMode = isChecked
            saveSettings()
            views.singleModeLayout.setVisibility(isChecked and View.GONE or View.VISIBLE)
            views.storyModeLayout.setVisibility(isChecked and View.VISIBLE or View.GONE)
        end
    })

    views.textInput.addTextChangedListener({
        afterTextChanged=function(editable)
            userText = editable.toString()
            local count = #userText
            views.charCountText.setText("Characters: " .. count .. " / " .. MAX_TOTAL_CHARS)
            views.charCountText.setTextColor(count > MAX_TOTAL_CHARS and 0xFFF44336 or 0xFF666666)
        end
    })
    
    views.fileNameInput.addTextChangedListener({ afterTextChanged=function(e) userFileName = e.toString() saveSettings() end })

    local function setSpinner(spinner, list, selectedItem, onChange)
        local adapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, list)
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        spinner.setAdapter(adapter)
        for i, v in ipairs(list) do if v == selectedItem then spinner.setSelection(i - 1) end end
        spinner.onItemSelectedListener = { onItemSelected=function(p, v, pos) onChange(list[pos + 1]) end }
    end

    setSpinner(views.voiceSpin, ALL_VOICES, selectedVoice, function(val) selectedVoice = val saveSettings() end)
    setSpinner(views.narratorSpin, NARRATOR_VOICES, selectedNarrator, function(val) selectedNarrator = val saveSettings() end)
    setSpinner(views.modelSpinSingle, TTS_MODELS, selectedModel, function(val) selectedModel = val saveSettings() end)
    setSpinner(views.modelSpinStory, TTS_MODELS, selectedModel, function(val) selectedModel = val saveSettings() end)

    views.playBtn.onClick = function()
        if not generatedAudioPath then showToast("Generate audio first") return end
        if mainMediaPlayer == nil then 
            initMainMediaPlayer() 
            pcall(function() 
                mainMediaPlayer.setDataSource(generatedAudioPath) 
                mainMediaPlayer.prepare() 
                mainMediaPlayer.setOnCompletionListener(MediaPlayer.OnCompletionListener{
                    onCompletion = function(mp)
                        isMainPlaying = false
                        runOnUi(function() views.playBtn.setText("PLAY") end)
                    end
                })
            end) 
        end
        toggleMainPlayPause(views.playBtn)
    end
    
    views.downloadBtn.onClick = function()
        if not generatedAudioPath then showToast("No audio found") return end
        local dest = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).getPath() .. "/" .. (userFileName ~= "" and userFileName or getDefaultFileName()) .. ".wav"
        local success = copyFile(generatedAudioPath, dest)
        if success then showToast("Downloaded to Mobile Storage!") else showToast("Failed to Download") end
    end

    views.generateBtn.onClick = function()
        local currentText = views.textInput.getText().toString()
        if currentText == "" then showToast("Please enter text first!") return end
        if not getWorkingApiKey() then showToast("Please configure API Key first!") showApiSettings() return end
        if #currentText > MAX_TOTAL_CHARS then showToast("Text exceeds " .. MAX_TOTAL_CHARS .. " characters limit!") return end

        userText = currentText
        if mainMediaPlayer ~= nil then if isMainPlaying then pcall(function() mainMediaPlayer.stop() end) isMainPlaying = false end pcall(function() mainMediaPlayer.release() end) mainMediaPlayer = nil end
        
        views.playBtn.setEnabled(false) views.playBtn.setText("PLAY") views.resultLayout.setVisibility(View.GONE)
        views.generateBtn.setEnabled(false) views.generateBtn.setText("GENERATING...") views.generateBtn.setBackgroundColor(0xFF9E9E9E)
        views.stopBtn.setEnabled(true)
        
        generateFullAudio(userText, isStoryMode, views.generateBtn, views.playBtn, views.resultLayout, views.statusText, views.stopBtn)
    end

    views.stopBtn.onClick = function()
        if cancellationRequested then return end
        cancellationRequested = true
        views.statusText.setText("Stopping... saving partial audio...") 
        views.generateBtn.setEnabled(true) views.generateBtn.setText("GENERATE AUDIO") views.generateBtn.setBackgroundColor(0xFF2196F3)
        views.stopBtn.setEnabled(false)
    end

    views.apiBtn.onClick = function() showApiSettings() end
    views.optBtn.onClick = function() showMoreOptions() end

end

showMain()