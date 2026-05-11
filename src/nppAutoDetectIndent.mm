/*
 * nppAutoDetectIndent plugin for Notepad++ macOS
 * Ported from nppAutoDetectIndent by Mike Tzou (Chocobo1)
 *
 * Automatically detects whether a file uses tabs or spaces for indentation,
 * and what the indent width is, then configures Scintilla accordingly.
 * Caches results per file path to avoid re-parsing on tab switch.
 *
 * Original: https://github.com/Chocobo1/nppAutoDetectIndent
 * License: GPLv3
 */

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"

#import <Cocoa/Cocoa.h>
#include <cstring>
#include <string>
#include <array>
#include <algorithm>
#include <unordered_map>

// ── Plugin state ────────────────────────────────────────────────────────

static const char *PLUGIN_NAME = "Auto Detect Indention";
static const int NB_FUNC = 4;
static FuncItem funcItem[NB_FUNC];
static NppData nppData;

static bool pluginDisabled = false;

// ── Forward declarations ────────────────────────────────────────────────

static void selectDisablePlugin();
static void doNothing();
static void gotoWebsite();

// ── Indent detection types ──────────────────────────────────────────────

static const int MAX_INDENTS = (80 * 2 / 3) + 1; // 2/3 of 80-width screen

enum class IndentType { Space, Tab, Invalid };

struct IndentInfo {
    IndentType type = IndentType::Invalid;
    int num = 0;
};

struct NppSettings {
    bool tabIndents = false;
    bool useTabs = false;
    bool backspaceIndents = false;
    int indents = 0;
};

// Indent cache: file path -> detected indent info
static std::unordered_map<std::string, IndentInfo> indentCache;
static NppSettings nppOriginalSettings;

// ── Helpers ─────────────────────────────────────────────────────────────

static NppHandle getCurScintilla()
{
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    if (which == -1) return 0;
    return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

static intptr_t sci(NppHandle h, uint32_t msg, uintptr_t w = 0, intptr_t l = 0)
{
    return nppData._sendMessage(h, msg, w, l);
}

static intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0)
{
    return nppData._sendMessage(nppData._nppHandle, msg, w, l);
}

static std::string getCurrentFilePath()
{
    char buf[4096] = {0};
    npp(NPPM_GETFULLCURRENTPATH, sizeof(buf) - 1, (intptr_t)buf);
    return std::string(buf);
}

// ── Comment continuation detection ──────────────────────────────────────

static bool isCommentContinuation(int langId, char c)
{
    // Canonical Windows NPP LangType values (Notepad_plus_msgs.h line 27).
    // Host v1.0.2 NPPM_GETCURRENTLANGTYPE returns these exact integers; any
    // other numbers we hardcode here would silently match the wrong language.
    switch (langId) {
        case 1:  // L_PHP
        case 2:  // L_C
        case 3:  // L_CPP
        case 4:  // L_CS
        case 5:  // L_OBJC
        case 6:  // L_JAVA
        case 58: // L_JAVASCRIPT
            return (c == '*');
        default:
            return false;
    }
}

// ── Document parsing ────────────────────────────────────────────────────

struct IndentionStats {
    int tabCount = 0;
    int spaceTotal = 0;
    std::array<int, 55> spaceCount{}; // MAX_INDENTS capped at 55
};

static IndentionStats parseDocument()
{
    NppHandle h = getCurScintilla();
    IndentionStats result;
    if (!h) return result;

    const int MAX_LINES = 5000;

    // Get language type
    int langId = 0;
    npp(NPPM_GETCURRENTLANGTYPE, 0, (intptr_t)&langId);

    int maxLines = std::min((int)sci(h, SCI_GETLINECOUNT), MAX_LINES);
    char textBuf[MAX_INDENTS + 3] = {0};

    for (int i = 0; i < maxLines; i++) {
        int indentWidth = (int)sci(h, SCI_GETLINEINDENTATION, (uintptr_t)i);
        if (indentWidth > MAX_INDENTS || indentWidth >= (int)result.spaceCount.size())
            continue;

        intptr_t pos = sci(h, SCI_POSITIONFROMLINE, (uintptr_t)i);

        // Read the indent area + first char after it
        int readLen = indentWidth + 1;
        if (readLen > (int)sizeof(textBuf) - 1) readLen = (int)sizeof(textBuf) - 1;

        struct Sci_TextRangeFull tr;
        tr.chrg.cpMin = (Sci_PositionCR)pos;
        tr.chrg.cpMax = (Sci_PositionCR)(pos + readLen);
        tr.lpstrText = textBuf;
        memset(textBuf, 0, sizeof(textBuf));
        sci(h, SCI_GETTEXTRANGEFULL, 0, (intptr_t)&tr);

        // Find first non-whitespace character
        char headChar = textBuf[0];
        char headCharAfterIndent = 0;
        for (int j = 0; j < readLen; j++) {
            if (textBuf[j] != '\t' && textBuf[j] != ' ') {
                headCharAfterIndent = textBuf[j];
                break;
            }
        }

        // Skip comment continuation lines (e.g., " * " in block comments)
        if (isCommentContinuation(langId, headCharAfterIndent))
            continue;

        if (headChar == '\t')
            result.tabCount++;
        if (headChar == ' ') {
            result.spaceTotal++;
            result.spaceCount[indentWidth]++;
        }
    }

    return result;
}

// ── Indent detection ────────────────────────────────────────────────────

static IndentInfo detectIndentInfo()
{
    IndentionStats result = parseDocument();
    IndentInfo info;

    // Decide type
    if (result.tabCount == 0 && result.spaceTotal == 0)
        info.type = IndentType::Invalid;
    else if (result.spaceTotal > (result.tabCount * 4))
        info.type = IndentType::Space;
    else if (result.tabCount > (result.spaceTotal * 4))
        info.type = IndentType::Tab;
    else
        info.type = IndentType::Invalid; // Ambiguous

    // Decide indent width for spaces
    if (info.type == IndentType::Space) {
        std::array<int, 55> tempCount{};

        for (int i = 2; i < (int)result.spaceCount.size(); i++) {
            for (int k = 2; k <= i; k++) {
                if ((i % k) == 0)
                    tempCount[k] += result.spaceCount[i];
            }
        }

        int which = 0;
        int weight = 0;
        for (int i = (int)tempCount.size() - 1; i >= 0; i--) {
            if (tempCount[i] > (weight * 3 / 2)) {
                weight = tempCount[i];
                which = i;
            }
        }

        info.num = which;
    }

    return info;
}

// ── Apply settings ──────────────────────────────────────────────────────

static void applyIndentInfo(const IndentInfo &info)
{
    NppHandle h = getCurScintilla();
    if (!h) return;

    switch (info.type) {
        case IndentType::Space:
            sci(h, SCI_SETTABINDENTS, 1);
            sci(h, SCI_SETUSETABS, 0);
            sci(h, SCI_SETBACKSPACEUNINDENTS, 1);
            sci(h, SCI_SETINDENT, (uintptr_t)info.num);
            break;

        case IndentType::Tab:
            sci(h, SCI_SETTABINDENTS, 1);
            sci(h, SCI_SETUSETABS, 1);
            sci(h, SCI_SETBACKSPACEUNINDENTS, 1);
            break;

        case IndentType::Invalid:
            break;
    }
}

static NppSettings detectNppSettings()
{
    NppHandle h = getCurScintilla();
    if (!h) return {};

    return {
        (bool)sci(h, SCI_GETTABINDENTS),
        (bool)sci(h, SCI_GETUSETABS),
        (bool)sci(h, SCI_GETBACKSPACEUNINDENTS),
        (int)sci(h, SCI_GETINDENT)
    };
}

static void applyNppSettings(const NppSettings &settings)
{
    NppHandle h = getCurScintilla();
    if (!h) return;

    sci(h, SCI_SETTABINDENTS, settings.tabIndents ? 1 : 0);
    sci(h, SCI_SETUSETABS, settings.useTabs ? 1 : 0);
    sci(h, SCI_SETBACKSPACEUNINDENTS, settings.backspaceIndents ? 1 : 0);
    sci(h, SCI_SETINDENT, (uintptr_t)settings.indents);
}

// ── Settings persistence (JSON) ─────────────────────────────────────────

static NSString *settingsPath()
{
    // Ask the host for its plugin config directory (creates it if needed).
    // Fall back to ~/.nextpad++ if NPPM_GETPLUGINSCONFIGDIR returns empty.
    char buf[1024] = {};
    nppData._sendMessage(nppData._nppHandle,
                         NPPM_GETPLUGINSCONFIGDIR,
                         (uintptr_t)sizeof(buf),
                         (intptr_t)buf);
    NSString *dir;
    if (buf[0] != '\0') {
        dir = [NSString stringWithUTF8String:buf];
    } else {
        dir = [NSHomeDirectory() stringByAppendingPathComponent:@".nextpad++"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    return [dir stringByAppendingPathComponent:@"nppAutoDetectIndent.json"];
}

static void loadSettings()
{
    @autoreleasepool {
        // One-shot migration from the pre-fix location
        // (~/.nextpad++/nppAutoDetectIndent.json → plugins/Config/).
        NSString *newPath = settingsPath();
        NSString *oldPath = [NSHomeDirectory() stringByAppendingPathComponent:
                             @".nextpad++/nppAutoDetectIndent.json"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![newPath isEqualToString:oldPath] &&
            [fm fileExistsAtPath:oldPath] &&
            ![fm fileExistsAtPath:newPath]) {
            [fm moveItemAtPath:oldPath toPath:newPath error:nil];
        }

        NSData *data = [NSData dataWithContentsOfFile:newPath];
        if (!data) return;
        NSError *err = nil;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (!dict || err) return;
        NSNumber *val = dict[@"disabled"];
        if (val) pluginDisabled = [val boolValue];
    }
}

static void saveSettings()
{
    @autoreleasepool {
        NSDictionary *dict = @{@"disabled": @(pluginDisabled)};
        NSError *err = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&err];
        if (data && !err) {
            [data writeToFile:settingsPath() atomically:YES];
        }
    }
}

// ── Menu check helper ───────────────────────────────────────────────────

static void updateMenuCheck()
{
    nppData._sendMessage(nppData._nppHandle, NPPM_SETMENUITEMCHECK,
                         (uintptr_t)funcItem[0]._cmdID,
                         (intptr_t)(pluginDisabled ? 1 : 0));
}

// ── Command functions ───────────────────────────────────────────────────

static void selectDisablePlugin()
{
    pluginDisabled = !pluginDisabled;
    updateMenuCheck();

    if (pluginDisabled) {
        indentCache.clear();
        applyNppSettings(nppOriginalSettings);
    } else {
        std::string path = getCurrentFilePath();
        IndentInfo info = detectIndentInfo();
        indentCache[path] = info;
        applyIndentInfo(info);
    }

    // Persist toggle state immediately so a force-quit can't lose it.
    saveSettings();
}

static void doNothing()
{
    // Placeholder for version menu item
}

static void gotoWebsite()
{
    @autoreleasepool {
        [[NSWorkspace sharedWorkspace] openURL:
            [NSURL URLWithString:@"https://github.com/Chocobo1/nppAutoDetectIndent"]];
    }
}

// ── Plugin exports ──────────────────────────────────────────────────────

extern "C" NPP_EXPORT void setInfo(NppData data)
{
    nppData = data;

    loadSettings();

    strlcpy(funcItem[0]._itemName, "Disable plugin", NPP_MENU_ITEM_SIZE);
    funcItem[0]._pFunc = selectDisablePlugin;
    funcItem[0]._init2Check = pluginDisabled;
    funcItem[0]._pShKey = nullptr;

    // Separator: host treats _pFunc == nullptr as NSMenuItem separatorItem
    funcItem[1]._itemName[0] = '\0';
    funcItem[1]._pFunc = nullptr;
    funcItem[1]._init2Check = false;
    funcItem[1]._pShKey = nullptr;

    strlcpy(funcItem[2]._itemName, "Version: 2.3", NPP_MENU_ITEM_SIZE);
    funcItem[2]._pFunc = doNothing;
    funcItem[2]._init2Check = false;
    funcItem[2]._pShKey = nullptr;

    strlcpy(funcItem[3]._itemName, "Goto website...", NPP_MENU_ITEM_SIZE);
    funcItem[3]._pFunc = gotoWebsite;
    funcItem[3]._init2Check = false;
    funcItem[3]._pShKey = nullptr;
}

extern "C" NPP_EXPORT const char *getName()
{
    return PLUGIN_NAME;
}

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF)
{
    *nbF = NB_FUNC;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *notifyCode)
{
    switch (notifyCode->nmhdr.code) {
        case NPPN_READY:
        {
            nppOriginalSettings = detectNppSettings();
            updateMenuCheck();
            break;
        }

        case NPPN_BUFFERACTIVATED:
        {
            if (pluginDisabled) break;

            std::string path = getCurrentFilePath();
            auto iter = indentCache.find(path);
            IndentInfo info;
            if (iter != indentCache.end()) {
                info = iter->second;
            } else {
                info = detectIndentInfo();
            }
            indentCache[path] = info;
            applyIndentInfo(info);
            break;
        }

        case NPPN_SHUTDOWN:
        {
            saveSettings();
            break;
        }

        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t /*msg*/, uintptr_t /*wParam*/, intptr_t /*lParam*/)
{
    return 1;
}
