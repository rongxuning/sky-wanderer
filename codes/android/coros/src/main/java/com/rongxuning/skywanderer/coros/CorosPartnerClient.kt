package com.rongxuning.skywanderer.coros

/**
 * Placeholder for COROS account linking.
 *
 * Sync is a cloud OAuth / Partner API, not a watch app. No client id, token
 * exchange, or HTTP call lives here yet.
 */
class CorosPartnerClient {
    val state: CorosLinkState = CorosLinkState.NotConfigured
}

enum class CorosLinkState {
    NotConfigured,
}
