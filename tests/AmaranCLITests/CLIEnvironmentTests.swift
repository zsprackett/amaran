import Testing
@testable import AmaranCLI

struct CLIEnvironmentTests {
    private let home = "/Users/test"

    @Test func defaultsMatchZshDispatcher() {
        let env = CLIEnvironment(environment: ["AMARAN_ROOT": "/repo"], home: home)
        #expect(env.statePath == "/Users/test/Library/Application Support/amaran-cli/state.json")
        #expect(env.daemonMetadataPath == "/Users/test/Library/Application Support/amaran-cli/daemon.json")
        #expect(env.appPath == "/repo/BluetoothProbe.app")
        #expect(env.daemonExecutablePath == "/repo/BluetoothProbe.app/Contents/MacOS/BluetoothProbe")
        #expect(env.launchAgentPlistPath == "/Users/test/Library/LaunchAgents/dev.local.bluetooth-probe.plist")
        #expect(env.logDir == "/Users/test/Library/Logs/amaran")
        #expect(env.daemonLabel == "dev.local.bluetooth-probe")
        #expect(env.logSubsystem == "dev.local.bluetooth-probe")
        #expect(env.daemonDisabled == false)
        #expect(env.timeout == 20)
        #expect(env.defaultNodeID == nil)
    }

    @Test func environmentOverridesAreHonored() {
        let env = CLIEnvironment(
            environment: [
                "AMARAN_ROOT": "/repo",
                "AMARAN_CLI_STATE_PATH": "/tmp/s.json",
                "AMARAN_DAEMON_PORT_FILE": "/tmp/d.json",
                "AMARAN_DAEMON_DISABLE": "1",
                "AMARAN_TIMEOUT": "45",
                "AMARAN_NODE_ID": "big",
            ],
            home: home)
        #expect(env.statePath == "/tmp/s.json")
        #expect(env.daemonMetadataPath == "/tmp/d.json")
        #expect(env.daemonDisabled == true)
        #expect(env.timeout == 45)
        #expect(env.defaultNodeID == "big")
    }

    @Test func timeoutFloorsAtOne() {
        let env = CLIEnvironment(environment: ["AMARAN_TIMEOUT": "0"], home: home)
        #expect(env.timeout == 1)
    }

    @Test func emptyNodeIdIsTreatedAsUnset() {
        let env = CLIEnvironment(environment: ["AMARAN_NODE_ID": ""], home: home)
        #expect(env.defaultNodeID == nil)
    }
}
