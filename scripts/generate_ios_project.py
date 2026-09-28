#!/usr/bin/env python3
"""Generate a dependency-free Xcode project referencing the local Swift package."""
from pathlib import Path
import plistlib

root = Path(__file__).resolve().parents[1]
version = plistlib.loads((root / 'iOS/BluetoothRelay/Info.plist').read_bytes())
project = root / 'iOS/BluetoothRelay.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('''// !$*UTF8*$!
{
 archiveVersion = 1; classes = {}; objectVersion = 56;
 objects = {
 A00000000000000000000001 = {isa = PBXProject; attributes = {LastUpgradeCheck = 1600; TargetAttributes = {A00000000000000000000002 = {CreatedOnToolsVersion = 16.0; }; }; }; buildConfigurationList = A00000000000000000000010; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = A00000000000000000000003; packageReferences = (A00000000000000000000030); productRefGroup = A00000000000000000000004; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000002); };
 A00000000000000000000002 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000011; buildPhases = (A00000000000000000000005, A00000000000000000000006, A00000000000000000000007); buildRules = (); dependencies = (); name = BluetoothRelay; packageProductDependencies = (A00000000000000000000031); productName = BluetoothRelay; productReference = A00000000000000000000008; productType = "com.apple.product-type.application"; };
 A00000000000000000000003 = {isa = PBXGroup; children = (A00000000000000000000009, A00000000000000000000004); sourceTree = "<group>"; };
 A00000000000000000000004 = {isa = PBXGroup; children = (A00000000000000000000008); name = Products; sourceTree = "<group>"; };
 A00000000000000000000005 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000024, A00000000000000000000025); runOnlyForDeploymentPostprocessing = 0; };
 A00000000000000000000006 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000032); runOnlyForDeploymentPostprocessing = 0; };
 A00000000000000000000007 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
 A00000000000000000000008 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = BluetoothRelay.app; sourceTree = BUILT_PRODUCTS_DIR; };
 A00000000000000000000009 = {isa = PBXGroup; children = (A00000000000000000000020, A00000000000000000000021, A00000000000000000000022); path = BluetoothRelay; sourceTree = "<group>"; };
 A00000000000000000000020 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RelayApp.swift; sourceTree = "<group>"; };
 A00000000000000000000021 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Scanner.swift; sourceTree = "<group>"; };
 A00000000000000000000022 = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
 A00000000000000000000024 = {isa = PBXBuildFile; fileRef = A00000000000000000000020; };
 A00000000000000000000025 = {isa = PBXBuildFile; fileRef = A00000000000000000000021; };
 A00000000000000000000030 = {isa = XCLocalSwiftPackageReference; relativePath = ..; };
 A00000000000000000000031 = {isa = XCSwiftPackageProductDependency; package = A00000000000000000000030; productName = BridgeCore; };
 A00000000000000000000032 = {isa = PBXBuildFile; productRef = A00000000000000000000031; };
 A00000000000000000000010 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000012, A00000000000000000000013); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
 A00000000000000000000011 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000014, A00000000000000000000015); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
 A00000000000000000000012 = {isa = XCBuildConfiguration; buildSettings = {CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 16.0; SWIFT_VERSION = 5.0; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf; }; name = Debug; };
 A00000000000000000000013 = {isa = XCBuildConfiguration; buildSettings = {CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 16.0; SWIFT_VERSION = 5.0; SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; }; name = Release; };
 A00000000000000000000014 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = BluetoothRelay/Info.plist; MARKETING_VERSION = 1.0; PRODUCT_BUNDLE_IDENTIFIER = local.wanmidi.BluetoothRelay; PRODUCT_NAME = "$(TARGET_NAME)"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TARGETED_DEVICE_FAMILY = 1; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks"; }; name = Debug; };
 A00000000000000000000015 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = BluetoothRelay/Info.plist; MARKETING_VERSION = 1.0; PRODUCT_BUNDLE_IDENTIFIER = local.wanmidi.BluetoothRelay; PRODUCT_NAME = "$(TARGET_NAME)"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TARGETED_DEVICE_FAMILY = 1; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks"; }; name = Release; };
 };
 rootObject = A00000000000000000000001;
}
'''.replace('CURRENT_PROJECT_VERSION = 1;', 'CURRENT_PROJECT_VERSION = ' + version['CFBundleVersion'] + ';')
    .replace('MARKETING_VERSION = 1.0;', 'MARKETING_VERSION = ' + version['CFBundleShortVersionString'] + ';'))
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
ref = '<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000002" BuildableName="BluetoothRelay.app" BlueprintName="BluetoothRelay" ReferencedContainer="container:BluetoothRelay.xcodeproj"/>'
(schemes / 'BluetoothRelay.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug"/>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(project)
