import Foundation
import AppKit
import CoreServices

/// YouTube / YouTube Music playback in Google Chrome or Safari, read through the
/// browsers' own AppleScript interfaces.
///
/// macOS has no public system-wide "Now Playing" API, so this is deliberately
/// narrow and privacy-preserving:
/// - The URL filter runs **inside the browser's script**: URLs of unrelated
///   tabs never reach this app; only tabs whose URL starts with one of
///   `allowedPrefixes` are returned, and they are re-validated here.
/// - Only the fixed JavaScript snippets below are executed, and only in those
///   tabs (re-checked in the same script right before executing).
/// - Reading playback state requires the browser's
///   "Allow JavaScript from Apple Events" option; without it only the presence
///   of a supported tab is reported and no playback status is guessed.
/// - Nothing is logged or stored; artwork is fetched only from YouTube/Google
///   image hosts over HTTPS.
enum BrowserMedia {
    enum Browser: String, CaseIterable, Codable, Identifiable {
        case chrome, safari
        var id: String { rawValue }
        var bundleID: String { self == .chrome ? "com.google.Chrome" : "com.apple.Safari" }
        var displayName: String { self == .chrome ? "Google Chrome" : "Safari" }
        /// Chrome's YouTube Music web app (PWA) runs inside Chrome's process.
        var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    }

    enum Site: String, Equatable {
        case youtubeMusic, youtube
        var displayName: String { self == .youtubeMusic ? "YouTube Music" : "YouTube" }
    }

    /// Exact HTTPS prefixes (with the trailing "/" so look-alike hosts such as
    /// "music.youtube.com.example" never match).
    static let allowedPrefixes = [
        "https://music.youtube.com/",
        "https://www.youtube.com/watch?",
        "https://youtube.com/watch?",
        "https://m.youtube.com/watch?",
        "https://www.youtube.com/shorts/",
    ]

    static let allowedHosts: Set<String> = ["music.youtube.com", "www.youtube.com", "youtube.com", "m.youtube.com"]

    /// Second, independent check of a URL returned by the browser.
    static func site(for urlString: String) -> Site? {
        guard allowedPrefixes.contains(where: { urlString.lowercased().hasPrefix($0) }),
              let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), allowedHosts.contains(host),
              components.port == nil, components.user == nil, components.password == nil
        else { return nil }
        return host == "music.youtube.com" ? .youtubeMusic : .youtube
    }

    /// Artwork is only downloaded from these HTTPS image hosts.
    static func isAllowedArtwork(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "i.ytimg.com" || host.hasSuffix(".ytimg.com")
            || host == "lh3.googleusercontent.com" || host.hasSuffix(".googleusercontent.com")
            || host.hasSuffix(".ggpht.com")
    }

    // MARK: Fixed JavaScript (never built from page or user data)

    /// Read-only: Media Session metadata plus the main media element's state.
    /// Read-only: Media Session metadata plus the state of the media element
    /// that is actually the page's player.
    ///
    /// A page can contain several `<video>` elements: YouTube's hover/inline
    /// preview players reuse the `html5-main-video` class, Shorts keep inactive
    /// players, YouTube Music pages can show video previews. Taking the first
    /// match reported another video's time (e.g. 7:38 / 9:43 while the song
    /// was at 0:57 / 3:39). So every element is scored — main player
    /// (`#movie_player`), not inside a preview container, duration matching
    /// the player's visible time ("0:57 / 3:39" in YouTube Music's player bar
    /// or YouTube's `.ytp-time-*`), playing, audible — and if the chosen
    /// element still disagrees with the visible time, the visible time wins
    /// (`ts` says which). During ads no time is reported.
    private static let playerIdentityJS = """
    var player=document.getElementById?document.getElementById('movie_player'):null;
    var playerData=player&&typeof player.getVideoData==='function'?player.getVideoData():null;
    var songLink=document.querySelector('ytmusic-player-bar .title[href]');
    var songMatch=songLink&&String(songLink.getAttribute('href')||'').match(/[?&]v=([A-Za-z0-9_-]+)/);
    var playerID=playerData&&String(playerData.video_id||'')||'';
    var songID=songMatch?songMatch[1]:'';
    """

    static let readJS = """
    (function(){try{var m=navigator.mediaSession&&navigator.mediaSession.metadata;\
    \(playerIdentityJS)
    function fin(x){return typeof x==='number'&&isFinite(x)&&x>=0;}\
    function hms(t){var p=String(t==null?'':t).trim().split(':');if(p.length<2||p.length>3)return null;var s=0;\
    for(var i=0;i<p.length;i++){var q=p[i].trim();if(!/^[0-9]+$/.test(q))return null;s=s*60+parseInt(q,10);}return s;}\
    function pair(a,b){var x=hms(a),y=hms(b);return(x!==null&&y!==null&&y>0&&x<=y+2)?{c:x,d:y}:null;}\
    var ui=null,musicUI=null,ti=document.querySelector('ytmusic-player-bar .time-info');\
    if(ti){var q=String(ti.textContent||'').split('/');if(q.length===2)ui=pair(q[0],q[1]);}\
    musicUI=ui;\
    if(!ui){var yc=document.querySelector('#movie_player .ytp-time-current'),yd=document.querySelector('#movie_player .ytp-time-duration');\
    if(yc&&yd)ui=pair(yc.textContent,yd.textContent);}\
    if(!ui){var b=document.querySelector('ytmusic-player-bar #progress-bar');if(b){var bn=Number(b.getAttribute('aria-valuenow')),bx=Number(b.getAttribute('aria-valuemax'));\
    if(fin(bn)&&fin(bx)&&bx>0&&bn<=bx+2)musicUI=ui={c:bn,d:bx};}}\
    var textUI=ui;\
    var mp=player,pa=null,pst=null;\
    if(mp&&typeof mp.getCurrentTime==='function'&&typeof mp.getDuration==='function'){var x=Number(mp.getCurrentTime()),y=Number(mp.getDuration());\
    if(fin(x)&&fin(y)&&y>0&&x<=y+2)pa={c:x,d:y};}if(mp&&typeof mp.getPlayerState==='function'){pst=Number(mp.getPlayerState());}\
    if(pa&&!musicUI)ui=pa;\
    var main=document.querySelector('#movie_player video.html5-main-video')||document.querySelector('#movie_player video')||document.querySelector('ytmusic-player video');\
    var list=document.querySelectorAll('video, audio'),e=main,best=-1e9;\
    for(var i=0;!main&&i<list.length;i++){var v=list[i],sc=0;\
    if(v.closest&&v.closest('#video-preview, ytd-video-preview, #inline-preview-player, ytd-reel-video-renderer:not([is-active])'))sc-=6;\
    if(ui&&fin(v.duration)&&Math.abs(v.duration-ui.d)<=2)sc+=3;if(!v.paused&&!v.ended)sc+=2;if(!v.muted&&v.volume>0)sc+=1;\
    if(!fin(v.duration)&&v.duration!==Infinity)sc-=2;if(sc>best){best=sc;e=v;}}\
    var ad=!!document.querySelector('#movie_player.ad-showing, .html5-video-player.ad-showing');\
    var c=null,d=null,src='none';if(e&&fin(e.currentTime)){c=e.currentTime;d=fin(e.duration)?e.duration:null;src='element';}\
    if(pa){c=pa.c;d=pa.d;src='player';}else if(e===main&&main&&fin(main.currentTime)&&fin(main.duration)&&main.duration>0){c=main.currentTime;d=main.duration;src='element';}\
    else if(ui&&!(d!==null&&Math.abs(d-ui.d)<=2)){c=ui.c;d=ui.d;src='ui';}\
    if(musicUI&&(c===null||d===null||Math.abs(c-musicUI.c)>1.5||Math.abs(d-musicUI.d)>2)){c=musicUI.c;d=musicUI.d;src='ui';}\
    if(playerID&&songID&&playerID!==songID){c=null;d=null;src='transition';}if(ad){c=null;d=null;src='ad';}\
    var pl=e?(!e.paused&&!e.ended):false;if(pst===1)pl=true;else if(pst===0||pst===2||pst===5)pl=false;\
    var a='';if(m&&m.artwork&&m.artwork.length){a=String(m.artwork[m.artwork.length-1].src||'');}\
    return JSON.stringify({t:m?String(m.title||''):'',r:m?String(m.artist||''):'',l:m?String(m.album||''):'',\
    w:a,id:songID||playerID,h:!!e||pst!==null,p:pl,c:c,d:d,s:navigator.mediaSession?String(navigator.mediaSession.playbackState||''):'',\
    mu:e?(!!e.muted||e.volume===0):false,rs:e?e.readyState:0,ts:src,n:list.length,ad:ad,\
    tu:textUI,tp:pa,te:(e&&fin(e.currentTime)&&fin(e.duration)&&e.duration>0)?{c:e.currentTime,d:e.duration}:null});\
    }catch(x){return '{"x":1}';}})()
    """

    /// `play`/`pause` are explicit (idempotent) intents: repeating one is
    /// harmless, so rapid taps can't leave the player in a surprising state.
    /// `playPause` (toggle) remains for paths that only have a toggle.
    enum Command: String { case playPause, play, pause, next, previous }

    /// The seek executes only if the same item is still loaded. This matters
    /// when autoplay changes the item between dragging and script execution.
    static func seekJS(seconds: TimeInterval, duration: TimeInterval, videoID: String?, title: String) -> String? {
        guard seconds.isFinite, seconds >= 0, duration.isFinite, duration > 0,
              let expected = try? JSONEncoder().encode(videoID ?? title),
              let literal = String(data: expected, encoding: .utf8) else { return nil }
        let identity = videoID != nil ? "(songID||playerID)" : #"""
        (String(navigator.mediaSession?.metadata?.title||'').trim()||
         String(document.title||'').trim().replace(/^\(\d+\)\s*/, '').replace(/ - YouTube(?: Music)?$/, ''))
        """#
        return """
        (function(){try{
        \(playerIdentityJS)
        if (\(identity) !== \(literal) || (songID && playerID && songID !== playerID)) return 'none';
        if (document.querySelector('#movie_player.ad-showing, .html5-video-player.ad-showing')) return 'none';
        var media=document.querySelector('#movie_player video.html5-main-video, #movie_player video, ytmusic-player video');
        var duration=player&&typeof player.getDuration==='function'?Number(player.getDuration()):0;
        function sameTimeline(value) { return Number.isFinite(value)&&value>0&&Math.abs(value-\(duration))<=2; }
        if (sameTimeline(duration)&&typeof player.seekTo==='function') {
            player.seekTo(Math.min(\(seconds),duration),true); return 'ok';
        }
        if (!media||!sameTimeline(media.duration)) return 'none';
        media.currentTime=Math.min(\(seconds),media.duration); return 'ok';
        }catch(e){return 'none';}})()
        """
    }

    /// Fixed control snippets. Order of preference: the YouTube player API on
    /// `#movie_player` (the same object the page's own controls drive), then
    /// the player-bar buttons, then the page's *main* media element — never the
    /// first `<video>` in the document, which can be a preview player.
    /// Presses a YouTube Music player-bar button exactly like one real click:
    /// one `click` event on the innermost `<button>` (newer `yt-icon-button`
    /// layouts listen there; the event still bubbles to the host). The old code
    /// called `.click()` on the host element, which those layouts ignore, yet
    /// reported "ok". Disabled buttons report "disabled"; a missing button
    /// returns "" so the caller can fall back — never two actions per press.
    static let pressOnceJS = "function press(sel){var b=document.querySelector(sel);if(!b)return '';" +
        "var t=(b.matches&&b.matches('button'))?b:(b.querySelector&&b.querySelector('button'))||b;" +
        "if(b.hasAttribute&&(b.hasAttribute('disabled')||b.getAttribute('aria-disabled')==='true'))return 'disabled';" +
        "if(t.hasAttribute&&(t.hasAttribute('disabled')||t.getAttribute('aria-disabled')==='true'))return 'disabled';" +
        "t.click();return 'ok';}"

    /// The new YouTube Music mini player has its own transport group. Use
    /// its real button, never another playlist or an older hidden player.
    private static func musicSkipJS(next: Bool) -> String {
        let labels = next ? "['next','next track','next song','下一個','下一个','下一首']"
                          : "['previous','previous track','previous song','上一個','上一个','上一首']"
        return """
        function missing(){
            return typeof window!=='undefined'&&window.matchMedia&&
                (window.matchMedia('(display-mode: standalone)').matches||
                 window.matchMedia('(display-mode: window-controls-overlay)').matches)?'none-standalone':'none';
        }
        var hosts=Array.from(document.querySelectorAll('.ytMusicMiniPlayerHost .ytmusicPlayerControlsHost'));
        if(hosts.length){
            function visible(node){return node.getClientRects().length>0&&getComputedStyle(node).visibility==='visible';}
            hosts=hosts.filter(visible);
            if(hosts.length!==1)return 'blocked';
            var buttons=Array.from(hosts[0].querySelectorAll('button[aria-label]')).filter(function(button){
                return visible(button)&&\(labels).includes(button.getAttribute('aria-label').trim().toLowerCase());
            });
            if(buttons.length>1)return 'blocked';
            if(!buttons.length)return missing();
            var button=buttons[0];
            if(button.disabled||button.getAttribute('aria-disabled')==='true')return 'disabled';
            button.click();return 'ok';
        }
        """
    }

    static func controlJS(_ command: Command, site: Site) -> String {
        let prelude = "var p=document.getElementById?document.getElementById('movie_player'):null;" +
            "function f(n){return p&&typeof p[n]==='function';}" +
            "var e=document.querySelector('#movie_player video.html5-main-video')||document.querySelector('#movie_player video')||document.querySelector('ytmusic-player video');"
        switch (command, site) {
        case (.play, _), (.pause, _):
            let wantPlay = command == .play
            // YouTube Music: its own button keeps the app's state in sync; press it only if needed.
            let button = site == .youtubeMusic
                ? "var b=document.querySelector('ytmusic-player-bar #play-pause-button');" +
                  "if(b&&e){if((!e.paused&&!e.ended)!==\(wantPlay)){b.click();}return 'ok';}" +
                  "if(b){var snapshot=JSON.parse(\(readJS));" +
                  "if(snapshot.h){if(snapshot.p!==\(wantPlay)){b.click();}return 'ok';}}"
                : ""
            return "(function(){\(prelude)if(f('playVideo')&&f('pauseVideo')){\(wantPlay ? "p.playVideo();" : "p.pauseVideo();")return 'ok';}" +
                "\(button)if(!e)return 'none';\(wantPlay ? "e.play();" : "e.pause();")return 'ok';})()"
        case (.playPause, _):
            let button = site == .youtubeMusic
                ? "var b=document.querySelector('ytmusic-player-bar #play-pause-button');if(b){b.click();return 'ok';}"
                : ""
            return "(function(){\(prelude)if(f('getPlayerState')&&f('playVideo')&&f('pauseVideo')){var s=Number(p.getPlayerState());" +
                "if(s===1||s===3){p.pauseVideo();}else{p.playVideo();}return 'ok';}\(button)" +
                "if(!e)return 'none';if(e.paused){e.play();}else{e.pause();}return 'ok';})()"
        case (.next, .youtubeMusic):
            return "(function(){\(Self.musicSkipJS(next: true))\(prelude)\(Self.pressOnceJS)return press('ytmusic-player-bar .next-button')||(f('nextVideo')?(p.nextVideo(),'ok'):missing());})()"
        case (.next, .youtube):
            return "(function(){\(prelude)var b=document.querySelector('.ytp-next-button');if(b&&b.getAttribute('aria-disabled')!=='true'&&b.offsetParent!==null){b.click();return 'ok';}return 'none';})()"
        case (.previous, .youtubeMusic):
            return "(function(){\(Self.musicSkipJS(next: false))\(prelude)\(Self.pressOnceJS)return press('ytmusic-player-bar .previous-button')||(f('previousVideo')?(p.previousVideo(),'ok'):missing());})()"
        case (.previous, .youtube):
            return "(function(){\(prelude)var b=document.querySelector('.ytp-prev-button');if(b&&b.offsetParent!==null){b.click();return 'ok';}" +
                "if(f('seekTo')){p.seekTo(0,true);return 'ok';}if(!e)return 'none';e.currentTime=0;return 'ok';})()"
        }
    }

    // MARK: AppleScript

    static let fieldSeparator = "\u{1F}"
    static let recordSeparator = "\u{1E}"

    private static func prefixCondition(_ variable: String, site: Site? = nil) -> String {
        let prefixes: [String]
        switch site {
        case .youtubeMusic: prefixes = Array(allowedPrefixes.prefix(1))
        case .youtube: prefixes = Array(allowedPrefixes.dropFirst())
        case nil: prefixes = allowedPrefixes
        }
        return prefixes.map { "\(variable) starts with \"\($0)\"" }.joined(separator: " or ")
    }

    /// AppleScript string literal for a fixed snippet (round-trip tested).
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Lists supported tabs and reads their state. Output records:
    /// `ref ␟ url ␟ title ␟ json-or-ERR:number:message ␞`
    static func listScript(for browser: Browser) -> String {
        let js = appleScriptString(readJS)
        switch browser {
        case .chrome:
            return """
            tell application id "com.google.Chrome"
                with timeout of \(scanTimeout) seconds
                set fs to (ASCII character 31)
                set rs to (ASCII character 30)
                set out to ""
                repeat with w in windows
                    set ts to {}
                    set windowID to ""
                    set urls to {}
                    try
                        set windowID to (id of w) as text
                        set ts to tabs of w
                        set urls to URL of every tab of w
                    end try
                    set tabIndex to 0
                    repeat with t in ts
                        set tabIndex to tabIndex + 1
                        try
                            set u to ""
                            try
                                if (count urls) is (count ts) then
                                    set candidateURL to (item tabIndex of urls) as text
                                    if \(prefixCondition("candidateURL")) then set u to (URL of t) as text
                                else
                                    set u to (URL of t) as text
                                end if
                            end try
                            if \(prefixCondition("u")) then
                                set r to ""
                                try
                                    set r to (execute t javascript \(js)) as text
                                on error m number n
                                    set r to "ERR:" & n & ":" & m
                                end try
                                set ti to ""
                                try
                                    set ti to (title of t) as text
                                end try
                                set out to out & windowID & "/" & ((id of t) as text) & fs & u & fs & ti & fs & r & rs
                            end if
                        end try
                    end repeat
                end repeat
                return out
                end timeout
            end tell
            """
        case .safari:
            return """
            tell application id "com.apple.Safari"
                with timeout of \(scanTimeout) seconds
                set fs to (ASCII character 31)
                set rs to (ASCII character 30)
                set out to ""
                repeat with w in windows
                    set i to 0
                    set ts to {}
                    try
                        set ts to tabs of w
                    end try
                    repeat with t in ts
                        set i to i + 1
                        try
                            set u to ""
                            try
                                set u to (URL of t) as text
                            end try
                            if \(prefixCondition("u")) then
                                set r to ""
                                try
                                    set r to (do JavaScript \(js) in t) as text
                                on error m number n
                                    set r to "ERR:" & n & ":" & m
                                end try
                                set ti to ""
                                try
                                    set ti to (name of t) as text
                                end try
                                set out to out & ((id of w) as text) & "/" & i & fs & u & fs & ti & fs & r & rs
                            end if
                        end try
                    end repeat
                end repeat
                return out
                end timeout
            end tell
            """
        }
    }

    /// Runs a fixed control snippet in exactly one tab, after re-checking its URL.
    /// Seconds an Apple Event may take before the script gives up (the system
    /// default is 2 minutes, which would stall every other command).
    static let controlTimeout = 3
    static let scanTimeout = 5

    /// Runs a fixed control snippet in exactly one tab, after re-checking its URL.
    /// With `readBack`, the same round trip also returns the tab's state:
    /// `result ␟ json` (result is "ok", "none", "gone" or "blocked").
    static func controlScript(for browser: Browser, ref: String, js: String, readBack: Bool = false, site: Site? = nil) -> String? {
        tabScript(for: browser, ref: ref, js: js, readBack: readBack, site: site)
    }

    /// Reads one tab only (fast confirmation after a control).
    static func readTabScript(for browser: Browser, ref: String) -> String? {
        tabScript(for: browser, ref: ref, js: nil, readBack: true)
    }

    private static func tabScript(for browser: Browser, ref: String, js: String?, readBack: Bool, site: Site? = nil) -> String? {
        let read = appleScriptString(readJS)
        func body(_ run: (String) -> String) -> String {
            var lines: [String] = []
            lines.append(js.map { "set r to (\(run(appleScriptString($0)))) as text" } ?? "set r to \"ok\"")
            if readBack {
                lines.append("set s to \"\"")
                lines.append("try")
                lines.append("set s to (\(run(read))) as text")
                lines.append("end try")
                lines.append("return r & (ASCII character 31) & s")
            } else {
                lines.append("return r")
            }
            return lines.joined(separator: "\n")
        }
        switch browser {
        case .chrome:
            let parts = ref.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 2, let windowID = Int(parts[0]), let tabID = Int(parts[1]) {
                // Window and tab IDs avoid querying every other Chrome tab.
                return """
                tell application id "com.google.Chrome"
                    with timeout of \(js == nil ? 1 : controlTimeout) seconds
                        try
                            set w to first window whose id is \(windowID)
                            set t to first tab of w whose id is \(tabID)
                        on error
                            return "gone"
                        end try
                        set u to (URL of t) as text
                        if \(prefixCondition("u", site: site)) then
                            \(body { "execute t javascript \($0)" })
                        end if
                        return "blocked"
                    end timeout
                end tell
                """
            }
            guard let tabID = Int(ref) else { return nil }
            return """
            tell application id "com.google.Chrome"
                with timeout of \(js == nil ? 1 : controlTimeout) seconds
                    repeat with w in windows
                        set ts to {}
                        try
                            set ts to tabs of w
                        end try
                        repeat with t in ts
                            set i to -1
                            try
                                set i to (id of t)
                            end try
                            if i is \(tabID) then
                                set u to (URL of t) as text
                                if \(prefixCondition("u", site: site)) then
                                    \(body { "execute t javascript \($0)" })
                                end if
                                return "blocked"
                            end if
                        end repeat
                    end repeat
                    return "gone"
                end timeout
            end tell
            """
        case .safari:
            let parts = ref.split(separator: "/")
            guard parts.count == 2, let windowID = Int(parts[0]), let index = Int(parts[1]) else { return nil }
            return """
            tell application id "com.apple.Safari"
                with timeout of \(js == nil ? 1 : controlTimeout) seconds
                    try
                        set t to tab \(index) of (first window whose id is \(windowID))
                    on error
                        return "gone"
                    end try
                    set u to (URL of t) as text
                    if \(prefixCondition("u", site: site)) then
                        \(body { "do JavaScript \($0) in t" })
                    end if
                    return "blocked"
                end timeout
            end tell
            """
        }
    }

    /// Splits `result ␟ json` from `controlScript(readBack:)` / `readTabScript`.
    static func parseControlResult(_ output: String) -> (result: String, stateJSON: String?) {
        guard let range = output.range(of: fieldSeparator) else { return (output, nil) }
        let json = String(output[range.upperBound...])
        return (String(output[..<range.lowerBound]), json.isEmpty ? nil : json)
    }

    static func controlSucceeded(_ result: String) -> Bool { result == "ok" }

    // MARK: Parsing

    struct TabState: Equatable {
        var browser: Browser
        var ref: String
        var site: Site
        var title: String
        var artist: String
        var album: String
        var artworkURL: URL?
        var isPlaying: Bool
        var position: TimeInterval?
        var duration: TimeInterval?
        /// Element muted or volume 0. (Chrome's per-tab "Mute site" is NOT
        /// visible to page scripts or AppleScript, so it can't be detected.)
        var isMuted = false
        /// HTMLMediaElement.readyState (0–4).
        var readyState = 4
        /// navigator.mediaSession.playbackState ("playing", "paused", "none" or "").
        var sessionState = ""
        /// Where position/duration came from: "element", "ui" (player's visible
        /// time), "ad" (ad playing: no time shown) or "none".
        var timeSource = "element"
        /// Media elements on the page (more than one = preview players exist).
        var mediaElementCount = 1
        var videoID: String? = nil
        /// Raw time sources as reported by the page (resolved by `TimeResolver`).
        var timeSamples: TimeSamples? = nil

        /// Stable while the same item plays in the same tab.
        var itemKey: String { videoID ?? "\(title)|\(artist)|\(album)" }
        var historyKey: String { "\(browser.rawValue)|\(ref)|\(itemKey)" }
    }

    enum Issue: Equatable {
        /// Supported tab found but "Allow JavaScript from Apple Events" is off.
        case javascriptDisabled
        /// Automation permission denied for this browser.
        case automationDenied
        /// Enabled, but the user hasn't answered the Automation prompt yet.
        /// Polling never prompts; the prompt comes from turning the toggle on
        /// or the "Allow Automation" button.
        case needsAutomation
        /// The YouTube Music web app (PWA) is running, but Chrome's scripting
        /// interface reported no music.youtube.com tab, so it can't be read.
        case youtubeMusicAppNotVisible
    }

    struct Scan: Equatable {
        var tabs: [TabState] = []
        var issue: Issue?
        /// Supported tabs seen (including ones whose state could not be read).
        var supportedTabCount = 0
        /// music.youtube.com tabs seen (readable or not).
        var musicTabCount = 0
        /// Supported tabs whose script failed for another reason.
        var unreadableCount = 0
    }

    static func parse(_ output: String, browser: Browser) -> Scan {
        var scan = Scan()
        for record in output.components(separatedBy: recordSeparator) where !record.isEmpty {
            let fields = record.components(separatedBy: fieldSeparator)
            guard fields.count >= 4, let site = site(for: fields[1]) else { continue }
            scan.supportedTabCount += 1
            if site == .youtubeMusic { scan.musicTabCount += 1 }
            let payload = fields[3...].joined(separator: fieldSeparator)
            if payload.hasPrefix("ERR:") {
                // Chrome: "Executing JavaScript through AppleScript is turned off…";
                // Safari: "…enable the 'Allow JavaScript from Apple Events' option…".
                let lower = payload.lowercased()
                if lower.contains("javascript") || lower.contains("apple events") {
                    scan.issue = .javascriptDisabled
                } else {
                    scan.unreadableCount += 1
                }
                continue
            }
            guard let state = parseState(payload, browser: browser, ref: fields[0], site: site, tabTitle: fields[2]) else { continue }
            scan.tabs.append(state)
        }
        return scan
    }

    static func parseState(_ json: String, browser: Browser, ref: String, site: Site, tabTitle: String) -> TabState? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["x"] == nil,
              (object["h"] as? Bool) == true else { return nil } // no media element: nothing to show
        var title = (object["t"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { title = cleanTabTitle(tabTitle, site: site) }
        guard !title.isEmpty else { return nil }
        let artwork = (object["w"] as? String).flatMap(URL.init(string:)).flatMap { isAllowedArtwork($0) ? $0 : nil }
        func number(_ key: String) -> Double? {
            guard let value = (object[key] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return nil }
            return value
        }
        var position = number("c"), duration = number("d")
        // Never show an impossible time (position past the end).
        if let p = position, let d = duration, p > d + 2 { position = nil; duration = nil }
        let videoID = (object["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        func sample(_ key: String) -> TimeSample? {
            guard let o = object[key] as? [String: Any],
                  let c = (o["c"] as? NSNumber)?.doubleValue, let d = (o["d"] as? NSNumber)?.doubleValue,
                  c.isFinite, d.isFinite, c >= 0, d > 0 else { return nil }
            return TimeSample(position: c, duration: d)
        }
        let source = (object["ts"] as? String) ?? "element"
        let raw = TimeSamples(ui: sample("tu"), player: sample("tp"), element: sample("te"),
                              blocked: source == "ad" || source == "transition")
        let hasRaw = object["tu"] != nil || object["tp"] != nil || object["te"] != nil
        return TabState(browser: browser, ref: ref, site: site, title: title,
                        artist: (object["r"] as? String) ?? "", album: (object["l"] as? String) ?? "",
                        artworkURL: artwork, isPlaying: (object["p"] as? Bool) ?? false,
                        position: position, duration: duration,
                        isMuted: (object["mu"] as? Bool) ?? false,
                        readyState: (object["rs"] as? NSNumber)?.intValue ?? 4,
                        sessionState: (object["s"] as? String) ?? "",
                        timeSource: (object["ts"] as? String) ?? "element",
                        mediaElementCount: (object["n"] as? NSNumber)?.intValue ?? 1,
                        videoID: videoID,
                        timeSamples: hasRaw ? raw : nil)
    }

    /// "Song - YouTube" → "Song"; strips a leading "(3) " notification count.
    static func cleanTabTitle(_ title: String, site: Site) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { text.removeSubrange(range) }
        for suffix in [" - YouTube Music", " - YouTube"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
            break
        }
        return text == "YouTube Music" || text == "YouTube" ? "" : text
    }

    // MARK: Selection

    /// Playback position seen per tab in earlier scans, to tell media that is
    /// really advancing from an element that merely isn't paused (stalled,
    /// frozen background tab, finished ad…).
    struct History: Equatable {
        struct Sample: Equatable { var position: TimeInterval; var date: Date; var stalledScans: Int }
        var samples: [String: Sample] = [:]
    }

    enum Progress: Equatable { case unknown, advancing, stalled }

    /// The web player can update the song identity before resetting the clock.
    struct TimeSample: Equatable {
        var position: TimeInterval
        var duration: TimeInterval
    }

    /// The page's time sources. They can disagree around a song change:
    /// YouTube Music's `<video>` may run one continuous timeline across songs,
    /// the player API can briefly keep the previous song's time, and the
    /// player-bar text can lag the title by a moment.
    struct TimeSamples: Equatable {
        var ui: TimeSample?
        var player: TimeSample?
        var element: TimeSample?
        /// Ad playing, or player and player bar show different videos.
        var blocked = false
    }

    /// Decides which time to show for the current item — or none. A time is
    /// shown only when (a) two sources agree, or (b) the single trusted source
    /// has been self-consistent for two samples; and never while it still
    /// looks like the previous item's timeline continuing. Uncertainty hides
    /// the progress line instead of stacking two songs' times.
    struct TimeResolver: Equatable {
        enum Source: String { case player, element, ui }

        static let agreeTolerance: TimeInterval = 2
        static let neededStreak = 2

        private var item: String?
        /// When the current item was first seen.
        private var changedAt: Date?
        private var previous: (sample: TimeSample, at: Date, playing: Bool)?
        private var accepted: (sample: TimeSample, at: Date, playing: Bool)?
        private var streaks: [String: (sample: TimeSample, at: Date, count: Int)] = [:]

        static func == (a: TimeResolver, b: TimeResolver) -> Bool { a.item == b.item }

        static func agree(_ a: TimeSample, _ b: TimeSample) -> Bool {
            abs(a.duration - b.duration) <= agreeTolerance && abs(a.position - b.position) <= agreeTolerance
        }

        private static func valid(_ s: TimeSample?) -> TimeSample? {
            guard let s, s.duration > 0, s.position >= 0, s.position <= s.duration + 2 else { return nil }
            return s
        }

        /// Updates the per-source consistency streak (advance ≈ elapsed while playing).
        private mutating func streak(_ name: Source, _ sample: TimeSample, playing: Bool, at date: Date) -> Int {
            var count = 1
            if let last = streaks[name.rawValue] {
                let elapsed = max(0, date.timeIntervalSince(last.at))
                let expected = playing ? elapsed : 0
                let moved = sample.position - last.sample.position
                if abs(sample.duration - last.sample.duration) <= 1,
                   abs(moved - expected) <= max(1.5, 0.5 * elapsed) { count = last.count + 1 }
            }
            streaks[name.rawValue] = (sample, date, count)
            return count
        }

        mutating func resolve(item newItem: String, samples: TimeSamples, isPlaying: Bool, at date: Date) -> (TimeSample, Source)? {
            if newItem != item {
                // Remember where the old item was, to recognise its timeline continuing.
                previous = accepted
                accepted = nil
                streaks = [:]
                item = newItem
                changedAt = date
            }
            guard !samples.blocked else { return nil }
            let ui = Self.valid(samples.ui), player = Self.valid(samples.player), element = Self.valid(samples.element)
            let ordered: [(Source, TimeSample)] = [(.player, player), (.element, element), (.ui, ui)].compactMap { name, s in s.map { (name, $0) } }
            var counts: [Source: Int] = [:]
            for (name, s) in ordered { counts[name] = streak(name, s, playing: isPlaying, at: date) }

            var candidate: (TimeSample, Source)?
            // (a) two independent sources agree → most precise of them.
            outer: for (i, (name, s)) in ordered.enumerated() {
                for (j, (_, other)) in ordered.enumerated() where j != i && Self.agree(s, other) {
                    candidate = (s, name); break outer
                }
            }
            // (b) a single trusted source that has been consistent: the visible
            // player-bar time if the page has one, else the player API, else the element.
            if candidate == nil {
                let trusted: (Source, TimeSample)? = ui.map { (.ui, $0) } ?? player.map { (.player, $0) } ?? element.map { (.element, $0) }
                if let (name, s) = trusted, (counts[name] ?? 0) >= Self.neededStreak, ordered.count == 1 || name == .ui {
                    candidate = (s, name)
                }
            }
            guard let (sample, name) = candidate else { return nil }
            // (c) still the previous item's timeline? Keep hiding — no time limit.
            if let previous, Self.continuesPrevious(sample, previous: previous, changedAt: changedAt ?? date, at: date) { return nil }
            previous = nil
            accepted = (sample, date, isPlaying)
            return (sample, name)
        }

        /// How long a same-length, not-earlier time may be treated as the
        /// previous item's stale display after a change.
        static let staleDisplayWindow: TimeInterval = 4
        /// Slack for a late-detected change (polling interval + read time).
        static let freshStartSlack: TimeInterval = 6

        /// Whether `sample` still looks like the previous item's timeline.
        /// Designed so a normal new song can never be hidden indefinitely:
        /// - consistent with starting at the change (≤ time since change + slack) → new song;
        /// - the open-ended rule needs the exact continuation signature and is
        ///   only used when the old position was far enough from 0 to be
        ///   distinguishable from a fresh start (the old rule hid a song forever
        ///   after skipping one only ~3 s in);
        /// - "same length, not earlier" is only trusted briefly after the change
        ///   (it hid similar-length songs whose first accepted sample came late).
        static func continuesPrevious(_ sample: TimeSample, previous: (sample: TimeSample, at: Date, playing: Bool),
                                      changedAt: Date, at date: Date) -> Bool {
            guard sample.position > 5 else { return false } // a new item starts near zero
            let sinceChange = max(0, date.timeIntervalSince(changedAt))
            if sample.position <= sinceChange + freshStartSlack { return false }
            let predicted = previous.sample.position + (previous.playing ? max(0, date.timeIntervalSince(previous.at)) : 0)
            if previous.sample.position > freshStartSlack, abs(sample.position - predicted) <= 3 { return true }
            if sinceChange <= staleDisplayWindow, abs(sample.duration - previous.sample.duration) <= 1,
               sample.position >= previous.sample.position - 1 { return true }
            return false
        }
    }

    struct TrackTransition {
        private var lastItem: String?
        private var lastPosition: TimeInterval?
        private var lastDuration: TimeInterval?
        private var carryover: (position: TimeInterval, changedAt: Date)?

        mutating func position(item: String, value: TimeInterval?, duration: TimeInterval?, at date: Date) -> TimeInterval? {
            if item != lastItem {
                carryover = nil
                if let lastPosition, let lastDuration, lastDuration - lastPosition <= 6 {
                    carryover = (lastPosition, date)
                }
                lastItem = item
                lastPosition = nil
                lastDuration = nil
            }
            guard let value, let duration else { return nil }
            if let carryover, value > 6, abs(value - carryover.position) <= 6,
               date.timeIntervalSince(carryover.changedAt) < 2.5 {
                return nil
            }
            carryover = nil
            lastPosition = value
            lastDuration = duration
            return value
        }
    }

    /// Two consecutive scans without movement while "playing" = stalled.
    static let stalledAfterScans = 2

    /// Compares with the previous sample and records the new one.
    static func progress(of tab: TabState, history: inout History, now: Date) -> Progress {
        guard let position = tab.position else { return .unknown }
        let key = tab.historyKey
        defer { if history.samples[key] == nil { history.samples[key] = .init(position: position, date: now, stalledScans: 0) } }
        guard let previous = history.samples[key] else { return .unknown }
        let elapsed = now.timeIntervalSince(previous.date)
        guard elapsed >= 0.5 else { return previous.stalledScans >= stalledAfterScans ? .stalled : .unknown }
        let moved = position - previous.position
        var stalled = previous.stalledScans
        let result: Progress
        if moved > min(0.25 * elapsed, 0.5) {
            stalled = 0
            result = .advancing
        } else if tab.isPlaying && abs(moved) < 0.05 {
            stalled += 1
            result = stalled >= stalledAfterScans ? .stalled : .unknown
        } else {
            stalled = 0 // seeked backwards, or paused: not evidence either way
            result = .unknown
        }
        history.samples[key] = .init(position: position, date: now, stalledScans: stalled)
        return result
    }

    /// Effectively playing: element not paused/ended and not known to be stalled.
    static func isEffectivelyPlaying(_ tab: TabState, progress: Progress) -> Bool {
        tab.isPlaying && progress != .stalled
    }

    /// Higher = more likely to be what the user is actually listening to.
    /// Audibility and real progress dominate; YouTube Music beats a YouTube
    /// video when both play; staying on the tab already shown is only a
    /// tie-breaker, so a stale choice can't hold the island.
    static func score(_ tab: TabState, progress: Progress, isPrevious: Bool) -> Int {
        var score = 0
        if !tab.isMuted { score += 40 }
        switch progress {
        case .advancing: score += 20
        case .unknown: break
        case .stalled: score -= 100
        }
        switch tab.sessionState {
        case "playing": score += 10
        case "paused": score -= 15
        default: break
        }
        if tab.readyState < 3 { score -= 5 } // buffering
        if tab.site == .youtubeMusic { score += 8 }
        if isPrevious { score += 3 }
        return score
    }

    struct Selection: Equatable {
        var tab: TabState?
        /// What to show as the playback state (false for a stalled "playing" element).
        var isPlaying: Bool
    }

    /// Picks the tab to show. `youtubeMusicAppUnseen`: the YT Music PWA runs
    /// but no music.youtube.com tab was found — then a merely *paused* old
    /// YouTube tab is not surfaced (it would hide the music the user hears).
    static func select(_ tabs: [TabState], previous: (Browser, String)?, history: inout History,
                       now: Date, youtubeMusicAppUnseen: Bool = false) -> Selection {
        var ranked: [(tab: TabState, score: Int, index: Int)] = []
        var progressByKey: [String: Progress] = [:]
        for (index, tab) in tabs.enumerated() {
            let progress = progress(of: tab, history: &history, now: now)
            progressByKey[tab.historyKey] = progress
            guard isEffectivelyPlaying(tab, progress: progress) else { continue }
            let isPrevious = previous.map { $0.0 == tab.browser && $0.1 == tab.ref } ?? false
            ranked.append((tab, score(tab, progress: progress, isPrevious: isPrevious), index))
        }
        // Forget tabs that disappeared (closed / navigated away).
        let live = Set(tabs.map(\.historyKey))
        history.samples = history.samples.filter { live.contains($0.key) }
        if let best = ranked.max(by: { $0.score == $1.score ? $0.index > $1.index : $0.score < $1.score }) {
            return Selection(tab: best.tab, isPlaying: true)
        }
        // Keep the known paused tab. If launched while YouTube Music is
        // paused, a single identifiable player is also safe to surface.
        if let previous, !youtubeMusicAppUnseen,
           let same = tabs.first(where: { $0.browser == previous.0 && $0.ref == previous.1 }) {
            return Selection(tab: same, isPlaying: false)
        }
        let pausedMusic = tabs.filter { $0.site == .youtubeMusic && !$0.isPlaying && $0.timeSource != "ad" }
        return Selection(tab: pausedMusic.count == 1 ? pausedMusic.first : nil, isPlaying: false)
    }

    /// Backwards-compatible single-shot selection (no progress history).
    static func choose(_ tabs: [TabState], previous: (Browser, String)?) -> TabState? {
        var history = History()
        return select(tabs, previous: previous, history: &history, now: Date()).tab
    }

    // MARK: YouTube Music web app (PWA)

    /// Chrome PWA shims are separate tiny apps (`com.google.Chrome.app.<id>`)
    /// whose Info.plist names the start URL; the window itself is owned by Chrome.
    static func isYouTubeMusicApp(bundleIdentifier: String?, startURL: String?) -> Bool {
        guard let id = bundleIdentifier, id.hasPrefix("com.google.Chrome.app."), let startURL else { return false }
        return site(for: startURL) == .youtubeMusic
    }

    /// Whether a YouTube Music PWA shim is running (reads only the shim's Info.plist).
    static func youtubeMusicAppIsRunning() -> Bool {
        !youtubeMusicApps().isEmpty
    }

    static func youtubeMusicApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier, id.hasPrefix("com.google.Chrome.app."), let url = app.bundleURL else { return false }
            return isYouTubeMusicApp(bundleIdentifier: id,
                                     startURL: Bundle(url: url)?.object(forInfoDictionaryKey: "CrAppModeShortcutURL") as? String)
        }
    }

    /// Per-browser result of the last scan, for the Settings diagnostics line.
    /// Contains counts and sites only — never URLs or titles.
    struct Diagnostics: Equatable {
        var date: Date
        var musicTabs = 0
        var musicPlaying = 0
        var videoTabs = 0
        var videoPlaying = 0
        var unreadable = 0
        var youtubeMusicAppRunning = false
        var shownSite: Site?
        var shownIsPlaying = false
        /// "element" / "ui" / "ad" / "none" for the shown tab, and its media element count.
        var shownTimeSource: String?
        var shownMediaElements = 0
    }

    // MARK: Automation permission (public AE API)

    enum Permission: Equatable { case granted, notDetermined, denied, browserNotRunning, unknown }

    /// `askIfNeeded == false` never shows a prompt. Must run off the main thread.
    nonisolated static func automationPermission(for browser: Browser, askIfNeeded: Bool) -> Permission {
        let target = NSAppleEventDescriptor(bundleIdentifier: browser.bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, askIfNeeded)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .browserNotRunning
        default: return .unknown
        }
    }
}
