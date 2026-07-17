enum DelegateTaskVoiceDeliveryClass: String, Sendable, Equatable {
    case routine
    case material
    case ownerResponseRequired = "owner_response_required"
    case silent
}
