import ArgumentParser

/// Root command for the amaran CLI. Subcommands are added per phase.
public struct AmaranCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "amaran",
        abstract: "Control amaran Bluetooth Mesh fixtures from the command line.",
        subcommands: [
            DoctorCommand.self, ListCommand.self, FixtureCommand.self,
            StateJoinCommand.self, StateInstallCommand.self, SidusImportCommand.self,
            OnCommand.self, OffCommand.self, IntensityCommand.self,
            CctCommand.self, GmCommand.self, StatusCommand.self, IdentifyCommand.self,
            SceneCommand.self, DaemonCommand.self,
            GattProbeCommand.self, ProbeCommand.self, ProvisionScanCommand.self,
            ProvisionInviteTestCommand.self, ProxyTestCommand.self, SigOnOffTestCommand.self,
            StatusTestCommand.self, ControlTestCommand.self, MonitorCommand.self,
            ConfigCompositionGetTestCommand.self, ConfigAppKeyGetTestCommand.self,
            ConfigAppKeyAddTestCommand.self, ConfigModelAppBindTestCommand.self,
            PairCommand.self, ProvisionTestCommand.self, ConfigureTestCommand.self,
            ConfigNodeResetTestCommand.self, JoinCaptureCommand.self,
            DiscoverCommand.self
        ]
    )

    public init() {}
}
