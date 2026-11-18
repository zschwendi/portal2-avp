# Portal 2 saves across Apple devices

Open **Saves** in the launcher to check iCloud, back up the current local save, or
choose between conflicting versions. **Play Offline** starts from this device’s
current save if the cloud check is slow. The app can also continue locally when
iCloud is unavailable. A save restore never runs while Portal 2 owns the save
directory.

On iPad and Vision Pro, **Continue** selects the newest valid campaign save after
this check. If iCloud restores a campaign onto a device with no local save,
**Play** can resume it directly. **Game Menu** opens the game's menu so you can
choose another slot or start a new campaign.

Portal 2 writes to `portal2/save` under the runtime’s existing `--user-dir`.
The adapter uses existing path casing, including `portal2/SAVE`. It snapshots the
whole directory as one generation so the game save, thumbnail, and auxiliary
level state stay together. Simultaneous changes to that generation are preserved
as separate versions. Choosing one makes it the current version while retaining
the other in recovery history. Game files, maps, graphics settings, and controller
settings stay in their existing locations.

On iPhone, iPad, and Vision Pro, reopen Portal 2 to check and sync after playing.
The engine can leave native threads alive after returning, so the launcher keeps
the save directory sealed for the rest of that process. The Mac launcher waits
for the full child process to exit before backing up. Its save lock is also held
by the Mac CLI runtime. Rebuild the native Mac executable with this source before
using the new launcher against the same save directory.

## Provisioned builds

Use the shared Cloud Documents container `iCloud.dev.zschwendi.portal2avp` for all
devices on one account. App IDs and provisioning profiles must be authorized for
that container. The standard unprovisioned build keeps its saves on the device.

- On iPhone and iPad, the existing `dev.zschwendi.portal2avp.ios` App ID can
  request the container with the `Portal2Cloud` scheme in `ios/signing/project.yml`.
  With a matching profile and signing identity, build with
  `python3 tools/build_ios.py --target device --icloud-saves`. The signer checks
  the requested container against the profile. Simulator and local-only device
  builds omit the cloud setting.
- On Vision Pro, generate the existing `Portal2Game` Xcode project. For the
  existing `dev.zschwendi.portal2avp.enginetest` App ID, set
  `CODE_SIGN_ENTITLEMENTS` to the absolute path of `visionos/Game-Cloud.entitlements`
  and `P2_ICLOUD_CONTAINER=iCloud.dev.zschwendi.portal2avp` in the device build.
  Those settings are optional for builds without an authorized account.
- On Apple Silicon Mac, pass `--cloud-signing-identity` and
  `--cloud-provisioning-profile` to `tools/make_app.py`. The profile must
  authorize the selected bundle ID and shared container. The existing bundle
  ID stays the default. A provisioned variant may pass `--bundle-id` to use its
  authorized Mac App ID, with the same configured game and save roots.

If you use a different authorized container, configure the same identifier on all
platforms and in their corresponding entitlements.

## Local verification

Run the adapter fixtures without Portal 2 game data.

```sh
swiftc -swift-version 6 -parse-as-library \
  apple/Saves/SnapshotSaves.swift apple/Saves/PortalSavePaths.swift \
  macos/PortalSaveWriterLease.swift tests/portal_save_checks.swift \
  -o /tmp/portal-save-check
/tmp/portal-save-check
```

The fixtures run two isolated local save stores, preserve the save generation as
a unit, exercise either reconnect order, and check that conflict resolution
converges without making duplicate revisions. The shared Port Forge suite also
covers stalled providers, late restore, interrupted upload and simulated peer
readback. Signed hardware builds and a real cloud round trip need separate
acceptance.
