# Which suites go in which `swift test` process when the AudioutCore suite is
# split across several at once. Sourced, not run. Read by scripts/run-tests.sh
# (a full run on the mule, and `--shard N`) and, through `--shard N`, by the
# GitHub `tests` workflow, so the two always split the suite the same way.
#
# Shard 1 is the suites whose files still hold blocking waits (Thread.sleep,
# RunLoop.run(until:), .wait(timeout:)); those hold a cooperative thread and
# starve Swift concurrency process-wide (see SuiteWait.swift and 8a1016d9), so
# they get a process of their own. Shard 2 is the alphabetical first half of
# the rest plus three main-actor suites moved in to balance it. Shard 3 is the
# serialized chains. The last shard (4) has no list: it is every suite not in
# the earlier lists (`--skip`), so a new suite file always runs without an edit
# here. A local full run on the mule still fans out to at most three processes
# (the run-tests.sh default), in which case the last process's `--skip` of
# lists 1 and 2 also carries list 3's suites, so coverage holds for any
# process count up to suite_shards_max.
#
# Each regex names whole suite types after `.` (top level) or `/` (nested,
# e.g. under SerializedSharedState).

suite_shards_max=4

suite_shard_1="AggregateOutputDeviceIdentityTests AggregateOutputDeviceTests \
AggregateOutputDeviceWiringTests AppRouteMixerTests \
CastFakeReceiverLoopTests CastLiveAudioServerRefusalTests \
CastLiveAudioServerTests CastOutputManagerTests CompanionEndToEndTests \
DACPServerTests DriftCorrectionApplierAnalyticsTests \
DriftCorrectionApplierSinkTests DriftCorrectionApplierTests \
LeveledAppInjectorTests NativeBackendGlobalStateTests NativeBackendTests \
NativeCaptureCoordinatorTests NativeDiscoveryLiveTests NativeDiscoveryTests \
PassiveDriftSamplerAnalyticsTests PassiveDriftSamplerTests \
PassiveDriftTrackerTests PerAppCaptureCoordinatorTests \
SyncDrawerCloseVetoTests SyncDrawerMountedKeyTests"

suite_shard_2="AboutSectionTests AccessibilitySignalSweepTests AirPlayHandoffWatcherTests \
AlignmentPlateCellTests AlignmentStageViewTests AlignmentTickInjectorTests \
AlignmentTokenContrastTests AnalyticsTests AppIconCacheTests \
AppRelaunchCommandTests AppRouteStoreTests AppRouteTargetEligibilityTests \
AppRoutingControllerTests AppRowViewTests AppSettingsTests \
AppSurfaceControllerTests AppTranslocationTests \
AudioCapturePermissionProbeTests AudioDiagTests AudioProcessResolverTests \
AudioSettingsLatencyTests AudioSettingsRemoteReloadTests \
AudioSettingsWakeRestoreTests BTAlignmentPosteriorTests \
BTAlignmentWizardProposalTelemetryTests BTAlignmentWizardSessionTests \
BTClockStabilityTests BTConnectionManagerTests BTDeviceEnumeratorTests \
BTDeviceRowTests BTFanoutTests BTHardwareVolumeStoreTests \
BTHardwareVolumeTests BTPopoverRowsTests BTSinkClockStormTests \
BTSpeakerTimingTests BTSyncDrawerAccordionTests BTSyncDrawerLayoutTests \
BTSyncDrawerViewTests BTSyncedSinkProtocolWitnessTests BTSyncedSinkTests \
BTSyncedSinkTestsRebuildTelemetry BTTrimStoreTests \
BackendKindResolutionTests BrandMarkTests BusRailCollapseResolveTests \
CardViewCollapseTrajectoryTests CastBrowserTests CastFeedDelayTests \
CastMessageCodecTests CastRoomDelayTests CastVolumePendingTests \
CompanionAlignmentOwnershipTests CompanionApprovalStoreTests \
CompanionCommandDispatcherTests CompanionCommandRateLimiterTests \
CompanionCopyTripwireTests CompanionLicenseActivationTests \
CompanionServerTests CompanionSnapshotBuilderTests CompanionWiringTests \
CompositedTokenContrastTests ConnectionDiagnosisViewTests \
ConnectionDiagnosticsTests ConnectionStateTests ControlPanelBackingViewTests \
ControlPanelWindowControllerTests DefaultOutputDeviceMonitorTests \
DefaultOutputSwitcherTests DeviceBluetoothKindTests DeviceCastKindTests \
DeviceDetailViewTests DeviceEQStoreTests DeviceEQTests \
DeviceIconResolverTests DeviceIconStoreTests DeviceIconWellViewTests \
DeviceIdentityTests DeviceLocalNetworkProofTests DeviceRowAirPlay1LiveTests \
DeviceRowConnectBrightenTests DeviceRowConnectionStateTests \
DeviceRowMutedStateTests DiagnosticsBundleTests DiscoverySettleTrackerTests \
DriftCorrectionPolicyTests EQEditorViewTests EQProcessorTests \
EQResponseCurveTests EmitterFieldTests EnergizeTests \
EqualizerEngagedMarkTests ExcludedAppsTests FeedColumnTests \
FoldAnimatorTests GeneralSettingsCompanionTests \
GeneralSettingsRememberedPhonesTests GroupControllerSyncedLocalFlipTests \
GroupControllerTests GroupEditorClickTargetTests GroupIconPersistenceTests \
GroupIdentityGlowViewTests GroupMasterVolumePersistenceTests \
MixerWindowControllerTests OnboardingUITests SettingsRootViewControllerTests"

# These .serialized chains set shard 3's end time, so they get a process where
# nothing crowds the main thread.
suite_shard_3="PopoverControllerTests PopoverBTAlignmentUITests PopoverDeviceVisibilityTests NativeBackendBTAlignmentInterceptTests LicenseGateTrialAnalyticsTests"

# suite_shards_names <i>
# Print list i. Only lists 1 to 3 exist; anything else prints nothing.
suite_shards_names() {
    case $1 in
        1) printf '%s\n' "$suite_shard_1" ;;
        2) printf '%s\n' "$suite_shard_2" ;;
        3) printf '%s\n' "$suite_shard_3" ;;
    esac
}

# suite_shards_args <i> <k>
# Set suite_shards_flag and suite_shards_regex for shard i of k: shard i < k
# runs `--filter` list i, shard k runs `--skip` lists 1..k-1. With k = 1 both
# are empty, which is a full run.
suite_shards_args() {
    suite_shards_flag=
    suite_shards_regex=
    [ "$2" -gt 1 ] || return 0
    if [ "$1" -lt "$2" ]; then
        suite_shards_flag=--filter
        _ss_names=$(suite_shards_names "$1")
    else
        suite_shards_flag=--skip
        _ss_names=
        _ss_i=1
        while [ "$_ss_i" -lt "$2" ]; do
            _ss_names="$_ss_names $(suite_shards_names "$_ss_i")"
            _ss_i=$((_ss_i + 1))
        done
    fi
    # $_ss_names is unquoted on purpose: word splitting turns the lists'
    # spaces and line breaks into one name per line.
    # shellcheck disable=SC2086
    suite_shards_regex="[./]($(printf '%s\n' $_ss_names | paste -sd '|' -))\\b"
}
