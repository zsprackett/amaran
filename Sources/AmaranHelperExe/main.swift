import AmaranHelperKit

// Thin executable shim. All behavior lives in AmaranHelperKit so the daemon
// logic can be unit tested; this entry point just hands off to it.
AmaranHelperMain.main()
