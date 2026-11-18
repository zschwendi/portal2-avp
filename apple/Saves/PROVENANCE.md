# Shared Port Forge save source

`SnapshotSaves.swift` is copied byte for byte from
`Sources/PortForgeCore/SnapshotSaves.swift` in the Port Forge snapshot save
integration at commit `14cfca3a9ad58b5b77c58a7c20847a2339632f41`. SHA-256 `30658a35f5e3875dcd876b0ffa2151e3b379d7e51909611a05671a5896ce3295`.
Update the library in Port Forge first and re-vendor the exact file here.

The remaining Swift sources in this directory select Portal 2’s existing save
directory and provide the game-specific launcher controls.
