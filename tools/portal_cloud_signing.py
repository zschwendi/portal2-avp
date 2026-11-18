"""Cloud Documents entitlements for the same Portal 2 save container on Apple targets."""
CONTAINER = 'iCloud.dev.zschwendi.portal2avp'
INFO_KEY = 'Portal2CloudContainer'


def cloud_entitlements(container):
    return {
        'com.apple.developer.icloud-services': ['CloudDocuments'],
        'com.apple.developer.icloud-container-identifiers': [container],
        'com.apple.developer.ubiquity-container-identifiers': [container],
    }


def authorize_cloud(profile_entitlements, container):
    requested = cloud_entitlements(container)
    for key, values in requested.items():
        allowed = profile_entitlements.get(key, [])
        if isinstance(allowed, str):
            allowed = [allowed]
        if '*' not in allowed and not set(values).issubset(allowed):
            raise ValueError(f'Provisioning profile must authorize {container} ({key})')
    return requested
