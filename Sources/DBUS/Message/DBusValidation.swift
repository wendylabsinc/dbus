extension DBusMessage {
  func validate(allowUnixFds: Bool, unixFdsError: DBusError) throws {
    let signature = try bodySignature()
    if body.isEmpty {
      if let signature, !signature.isEmpty {
        throw DBusError.invalidBody
      }
    } else {
      guard let signature else {
        throw DBusError.invalidHeader
      }
      if signature.isEmpty {
        throw DBusError.invalidBody
      }
      let typeSignature = try DBusTypeSignature(signature)
      guard typeSignature.types.count == body.count else {
        throw DBusError.invalidBody
      }
      for (value, type) in zip(body, typeSignature.types) {
        try value.validate(against: type)
      }
    }

    let usedIndices = bodyUnixFdIndices()
    if !allowUnixFds {
      if !usedIndices.isEmpty || !unixFds.isEmpty {
        throw unixFdsError
      }
    } else if usedIndices.isEmpty {
      if !unixFds.isEmpty {
        throw DBusError.invalidBody
      }
    } else {
      guard !unixFds.isEmpty else {
        throw DBusError.unixFdMissing
      }
      guard let maxIndex = usedIndices.max() else {
        throw DBusError.unixFdMissing
      }
      if unixFds.count <= Int(maxIndex) {
        throw DBusError.unixFdMissing
      }
      if unixFds.count != Int(maxIndex) + 1 {
        throw DBusError.invalidBody
      }
      if usedIndices.count != unixFds.count {
        throw DBusError.invalidBody
      }
    }
  }

  private func bodySignature() throws -> String? {
    guard let field = headerFields.first(where: { $0.code == .signature }) else {
      return nil
    }
    guard case .signature(let signature) = field.variant.value else {
      throw DBusError.invalidHeaderField
    }
    do {
      _ = try DBusTypeSignature(signature)
    } catch {
      throw DBusError.invalidSignature
    }
    return signature
  }

  private func bodyUnixFdIndices() -> Set<UInt32> {
    body.reduce(into: Set<UInt32>()) { partial, value in
      partial.formUnion(value.unixFdIndices())
    }
  }
}

extension DBusValue {
  fileprivate func validate(against type: DBusType) throws {
    switch type {
    case .byte:
      guard case .byte = self else { throw DBusError.invalidBody }
    case .boolean:
      guard case .boolean = self else { throw DBusError.invalidBody }
    case .int16:
      guard case .int16 = self else { throw DBusError.invalidBody }
    case .uint16:
      guard case .uint16 = self else { throw DBusError.invalidBody }
    case .int32:
      guard case .int32 = self else { throw DBusError.invalidBody }
    case .uint32:
      guard case .uint32 = self else { throw DBusError.invalidBody }
    case .int64:
      guard case .int64 = self else { throw DBusError.invalidBody }
    case .uint64:
      guard case .uint64 = self else { throw DBusError.invalidBody }
    case .double:
      guard case .double = self else { throw DBusError.invalidBody }
    case .string:
      guard case .string = self else { throw DBusError.invalidBody }
    case .objectPath:
      guard case .objectPath(let path) = self,
        HeaderField.isValidObjectPath(path)
      else {
        throw DBusError.invalidBody
      }
    case .signature:
      guard case .signature(let signature) = self else { throw DBusError.invalidBody }
      do {
        _ = try DBusTypeSignature(signature)
      } catch {
        throw DBusError.invalidSignature
      }
    case .unixFd:
      guard case .unixFd = self else { throw DBusError.invalidBody }
    case .variant:
      guard case .variant(let variant) = self else { throw DBusError.invalidBody }
      try variant.validate()
    case .array(let elementType):
      switch self {
      case .array(let values):
        if case .dictEntry = elementType {
          throw DBusError.invalidBody
        }
        for value in values {
          try value.validate(against: elementType)
        }
      case .dictionary(let entries):
        guard case .dictEntry(let keyType, let valueType) = elementType else {
          throw DBusError.invalidBody
        }
        for (key, value) in entries {
          try key.validate(against: keyType)
          try value.validate(against: valueType)
        }
      default:
        throw DBusError.invalidBody
      }
    case .dictEntry:
      throw DBusError.invalidBody
    case .structure(let types):
      guard case .structure(let values) = self, values.count == types.count else {
        throw DBusError.invalidBody
      }
      for (value, type) in zip(values, types) {
        try value.validate(against: type)
      }
    }
  }

  fileprivate func unixFdIndices() -> Set<UInt32> {
    switch self {
    case .unixFd(let index):
      return [index]
    case .variant(let variant):
      return variant.value.unixFdIndices()
    case .array(let values):
      return values.reduce(into: Set<UInt32>()) { partial, value in
        partial.formUnion(value.unixFdIndices())
      }
    case .structure(let values):
      return values.reduce(into: Set<UInt32>()) { partial, value in
        partial.formUnion(value.unixFdIndices())
      }
    case .dictionary(let entries):
      var indices = Set<UInt32>()
      for key in entries.keys {
        indices.formUnion(key.unixFdIndices())
      }
      for value in entries.values {
        indices.formUnion(value.unixFdIndices())
      }
      return indices
    default:
      return []
    }
  }
}

extension DBusVariant {
  fileprivate func validate() throws {
    let typeSignature: DBusTypeSignature
    do {
      typeSignature = try DBusTypeSignature(signature)
    } catch {
      throw DBusError.invalidSignature
    }
    guard typeSignature.types.count == 1, let type = typeSignature.types.first else {
      throw DBusError.invalidBody
    }
    try value.validate(against: type)
  }
}
