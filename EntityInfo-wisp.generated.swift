// Generated using the ObjectBox Swift Generator — https://objectbox.io
// DO NOT EDIT

// swiftlint:disable all
import ObjectBox
import Foundation

// MARK: - Entity metadata

// PROJECT NOTE: each `extension` and binding below is prefixed with
// `nonisolated` so it doesn't inherit `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
// Persistence is not UI work and the generated `static var` property
// descriptors are referenced from inside `actor EventStore` / `actor GroupStore`.
// On regeneration, re-apply this prefix to every extension and binding class.


nonisolated extension EventEntity: ObjectBox.Entity {}
nonisolated extension GroupMessageEntity: ObjectBox.Entity {}
nonisolated extension GroupMetaEntity: ObjectBox.Entity {}

nonisolated extension EventEntity: ObjectBox.__EntityRelatable {
    internal typealias EntityType = EventEntity

    internal var _id: EntityId<EventEntity> {
        return EntityId<EventEntity>(self.id.value)
    }
}

nonisolated extension EventEntity: ObjectBox.EntityInspectable {
    internal typealias EntityBindingType = EventEntityBinding

    /// Generated metadata used by ObjectBox to persist the entity.
    internal static let entityInfo = ObjectBox.EntityInfo(name: "EventEntity", id: 1)

    internal static let entityBinding = EntityBindingType()

    fileprivate static func buildEntity(modelBuilder: ObjectBox.ModelBuilder) throws {
        let entityBuilder = try modelBuilder.entityBuilder(for: EventEntity.self, id: 1, uid: 4227522170458110720)
        try entityBuilder.addProperty(name: "id", type: PropertyType.long, flags: [.id], id: 1, uid: 4446663439666365696)
        try entityBuilder.addProperty(name: "eventId", type: PropertyType.string, flags: [.unique, .indexHash, .indexed], id: 2, uid: 9064520196199985408, indexId: 1, indexUid: 5390326825860458496)
        try entityBuilder.addProperty(name: "pubkey", type: PropertyType.string, flags: [.indexHash, .indexed], id: 3, uid: 1073492786699545088, indexId: 2, indexUid: 2305756830040454400)
        try entityBuilder.addProperty(name: "createdAt", type: PropertyType.long, id: 4, uid: 8317748338084210688)
        try entityBuilder.addProperty(name: "kind", type: PropertyType.long, flags: [.indexed], id: 5, uid: 4410330658802766080, indexId: 3, indexUid: 5334311138029547776)
        try entityBuilder.addProperty(name: "content", type: PropertyType.string, id: 6, uid: 4805220737910422016)
        try entityBuilder.addProperty(name: "tags", type: PropertyType.string, id: 7, uid: 7578578939852631040)
        try entityBuilder.addProperty(name: "sig", type: PropertyType.string, id: 8, uid: 1086054297639166208)
        try entityBuilder.addProperty(name: "insertedAt", type: PropertyType.long, id: 9, uid: 5355631664594474496)

        try entityBuilder.lastProperty(id: 9, uid: 5355631664594474496)
    }
}

nonisolated extension EventEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { EventEntity.id == myId }
    internal static var id: Property<EventEntity, Id, Id> { return Property<EventEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { EventEntity.eventId.startsWith("X") }
    internal static var eventId: Property<EventEntity, String, Void> { return Property<EventEntity, String, Void>(propertyId: 2, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { EventEntity.pubkey.startsWith("X") }
    internal static var pubkey: Property<EventEntity, String, Void> { return Property<EventEntity, String, Void>(propertyId: 3, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { EventEntity.createdAt > 1234 }
    internal static var createdAt: Property<EventEntity, Int, Void> { return Property<EventEntity, Int, Void>(propertyId: 4, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { EventEntity.kind > 1234 }
    internal static var kind: Property<EventEntity, Int, Void> { return Property<EventEntity, Int, Void>(propertyId: 5, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { EventEntity.content.startsWith("X") }
    internal static var content: Property<EventEntity, String, Void> { return Property<EventEntity, String, Void>(propertyId: 6, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { EventEntity.tags.startsWith("X") }
    internal static var tags: Property<EventEntity, String, Void> { return Property<EventEntity, String, Void>(propertyId: 7, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { EventEntity.sig.startsWith("X") }
    internal static var sig: Property<EventEntity, String, Void> { return Property<EventEntity, String, Void>(propertyId: 8, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { EventEntity.insertedAt > 1234 }
    internal static var insertedAt: Property<EventEntity, Int, Void> { return Property<EventEntity, Int, Void>(propertyId: 9, isPrimaryKey: false) }

    fileprivate func __setId(identifier: ObjectBox.Id) {
        self.id = Id(identifier)
    }
}

nonisolated extension ObjectBox.Property where E == EventEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .id == myId }

    internal static var id: Property<EventEntity, Id, Id> { return Property<EventEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .eventId.startsWith("X") }

    internal static var eventId: Property<EventEntity, String, Void> { return Property<EventEntity, String, Void>(propertyId: 2, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .pubkey.startsWith("X") }

    internal static var pubkey: Property<EventEntity, String, Void> { return Property<EventEntity, String, Void>(propertyId: 3, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .createdAt > 1234 }

    internal static var createdAt: Property<EventEntity, Int, Void> { return Property<EventEntity, Int, Void>(propertyId: 4, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .kind > 1234 }

    internal static var kind: Property<EventEntity, Int, Void> { return Property<EventEntity, Int, Void>(propertyId: 5, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .content.startsWith("X") }

    internal static var content: Property<EventEntity, String, Void> { return Property<EventEntity, String, Void>(propertyId: 6, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .tags.startsWith("X") }

    internal static var tags: Property<EventEntity, String, Void> { return Property<EventEntity, String, Void>(propertyId: 7, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .sig.startsWith("X") }

    internal static var sig: Property<EventEntity, String, Void> { return Property<EventEntity, String, Void>(propertyId: 8, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .insertedAt > 1234 }

    internal static var insertedAt: Property<EventEntity, Int, Void> { return Property<EventEntity, Int, Void>(propertyId: 9, isPrimaryKey: false) }

}


/// Generated service type to handle persisting and reading entity data. Exposed through `EventEntity.EntityBindingType`.
nonisolated internal final class EventEntityBinding: ObjectBox.EntityBinding, Sendable {
    internal typealias EntityType = EventEntity
    internal typealias IdType = Id

    internal required init() {}

    internal func generatorBindingVersion() -> Int { 1 }

    internal func setEntityIdUnlessStruct(of entity: EntityType, to entityId: ObjectBox.Id) {
        entity.__setId(identifier: entityId)
    }

    internal func entityId(of entity: EntityType) -> ObjectBox.Id {
        return entity.id.value
    }

    internal func collect(fromEntity entity: EntityType, id: ObjectBox.Id,
                                  propertyCollector: ObjectBox.FlatBufferBuilder, store: ObjectBox.Store) throws {
        let propertyOffset_eventId = propertyCollector.prepare(string: entity.eventId)
        let propertyOffset_pubkey = propertyCollector.prepare(string: entity.pubkey)
        let propertyOffset_content = propertyCollector.prepare(string: entity.content)
        let propertyOffset_tags = propertyCollector.prepare(string: entity.tags)
        let propertyOffset_sig = propertyCollector.prepare(string: entity.sig)

        propertyCollector.collect(id, at: 2 + 2 * 1)
        propertyCollector.collect(entity.createdAt, at: 2 + 2 * 4)
        propertyCollector.collect(entity.kind, at: 2 + 2 * 5)
        propertyCollector.collect(entity.insertedAt, at: 2 + 2 * 9)
        propertyCollector.collect(dataOffset: propertyOffset_eventId, at: 2 + 2 * 2)
        propertyCollector.collect(dataOffset: propertyOffset_pubkey, at: 2 + 2 * 3)
        propertyCollector.collect(dataOffset: propertyOffset_content, at: 2 + 2 * 6)
        propertyCollector.collect(dataOffset: propertyOffset_tags, at: 2 + 2 * 7)
        propertyCollector.collect(dataOffset: propertyOffset_sig, at: 2 + 2 * 8)
    }

    internal func createEntity(entityReader: ObjectBox.FlatBufferReader, store: ObjectBox.Store) -> EntityType {
        let entity = EventEntity()

        entity.id = entityReader.read(at: 2 + 2 * 1)
        entity.eventId = entityReader.read(at: 2 + 2 * 2)
        entity.pubkey = entityReader.read(at: 2 + 2 * 3)
        entity.createdAt = entityReader.read(at: 2 + 2 * 4)
        entity.kind = entityReader.read(at: 2 + 2 * 5)
        entity.content = entityReader.read(at: 2 + 2 * 6)
        entity.tags = entityReader.read(at: 2 + 2 * 7)
        entity.sig = entityReader.read(at: 2 + 2 * 8)
        entity.insertedAt = entityReader.read(at: 2 + 2 * 9)

        return entity
    }
}



nonisolated extension GroupMessageEntity: ObjectBox.__EntityRelatable {
    internal typealias EntityType = GroupMessageEntity

    internal var _id: EntityId<GroupMessageEntity> {
        return EntityId<GroupMessageEntity>(self.id.value)
    }
}

nonisolated extension GroupMessageEntity: ObjectBox.EntityInspectable {
    internal typealias EntityBindingType = GroupMessageEntityBinding

    /// Generated metadata used by ObjectBox to persist the entity.
    internal static let entityInfo = ObjectBox.EntityInfo(name: "GroupMessageEntity", id: 2)

    internal static let entityBinding = EntityBindingType()

    fileprivate static func buildEntity(modelBuilder: ObjectBox.ModelBuilder) throws {
        let entityBuilder = try modelBuilder.entityBuilder(for: GroupMessageEntity.self, id: 2, uid: 6049565361519769600)
        try entityBuilder.addProperty(name: "id", type: PropertyType.long, flags: [.id], id: 1, uid: 2161449300401449216)
        try entityBuilder.addProperty(name: "eventId", type: PropertyType.string, flags: [.unique, .indexHash, .indexed], id: 2, uid: 5407304030095647488, indexId: 4, indexUid: 2058850291372696064)
        try entityBuilder.addProperty(name: "roomKey", type: PropertyType.string, flags: [.indexHash, .indexed], id: 3, uid: 2061848734451418368, indexId: 5, indexUid: 1343850577219974144)
        try entityBuilder.addProperty(name: "senderPubkey", type: PropertyType.string, id: 4, uid: 3245393344450273024)
        try entityBuilder.addProperty(name: "content", type: PropertyType.string, id: 5, uid: 5470578834998431744)
        try entityBuilder.addProperty(name: "createdAt", type: PropertyType.long, flags: [.indexed], id: 6, uid: 5319114696457033472, indexId: 6, indexUid: 5006852002354063616)
        try entityBuilder.addProperty(name: "replyToId", type: PropertyType.string, id: 7, uid: 125460329649292032)

        try entityBuilder.lastProperty(id: 7, uid: 125460329649292032)
    }
}

nonisolated extension GroupMessageEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMessageEntity.id == myId }
    internal static var id: Property<GroupMessageEntity, Id, Id> { return Property<GroupMessageEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMessageEntity.eventId.startsWith("X") }
    internal static var eventId: Property<GroupMessageEntity, String, Void> { return Property<GroupMessageEntity, String, Void>(propertyId: 2, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMessageEntity.roomKey.startsWith("X") }
    internal static var roomKey: Property<GroupMessageEntity, String, Void> { return Property<GroupMessageEntity, String, Void>(propertyId: 3, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMessageEntity.senderPubkey.startsWith("X") }
    internal static var senderPubkey: Property<GroupMessageEntity, String, Void> { return Property<GroupMessageEntity, String, Void>(propertyId: 4, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMessageEntity.content.startsWith("X") }
    internal static var content: Property<GroupMessageEntity, String, Void> { return Property<GroupMessageEntity, String, Void>(propertyId: 5, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMessageEntity.createdAt > 1234 }
    internal static var createdAt: Property<GroupMessageEntity, Int, Void> { return Property<GroupMessageEntity, Int, Void>(propertyId: 6, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMessageEntity.replyToId.startsWith("X") }
    internal static var replyToId: Property<GroupMessageEntity, String?, Void> { return Property<GroupMessageEntity, String?, Void>(propertyId: 7, isPrimaryKey: false) }

    fileprivate func __setId(identifier: ObjectBox.Id) {
        self.id = Id(identifier)
    }
}

nonisolated extension ObjectBox.Property where E == GroupMessageEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .id == myId }

    internal static var id: Property<GroupMessageEntity, Id, Id> { return Property<GroupMessageEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .eventId.startsWith("X") }

    internal static var eventId: Property<GroupMessageEntity, String, Void> { return Property<GroupMessageEntity, String, Void>(propertyId: 2, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .roomKey.startsWith("X") }

    internal static var roomKey: Property<GroupMessageEntity, String, Void> { return Property<GroupMessageEntity, String, Void>(propertyId: 3, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .senderPubkey.startsWith("X") }

    internal static var senderPubkey: Property<GroupMessageEntity, String, Void> { return Property<GroupMessageEntity, String, Void>(propertyId: 4, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .content.startsWith("X") }

    internal static var content: Property<GroupMessageEntity, String, Void> { return Property<GroupMessageEntity, String, Void>(propertyId: 5, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .createdAt > 1234 }

    internal static var createdAt: Property<GroupMessageEntity, Int, Void> { return Property<GroupMessageEntity, Int, Void>(propertyId: 6, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .replyToId.startsWith("X") }

    internal static var replyToId: Property<GroupMessageEntity, String?, Void> { return Property<GroupMessageEntity, String?, Void>(propertyId: 7, isPrimaryKey: false) }

}


/// Generated service type to handle persisting and reading entity data. Exposed through `GroupMessageEntity.EntityBindingType`.
nonisolated internal final class GroupMessageEntityBinding: ObjectBox.EntityBinding, Sendable {
    internal typealias EntityType = GroupMessageEntity
    internal typealias IdType = Id

    internal required init() {}

    internal func generatorBindingVersion() -> Int { 1 }

    internal func setEntityIdUnlessStruct(of entity: EntityType, to entityId: ObjectBox.Id) {
        entity.__setId(identifier: entityId)
    }

    internal func entityId(of entity: EntityType) -> ObjectBox.Id {
        return entity.id.value
    }

    internal func collect(fromEntity entity: EntityType, id: ObjectBox.Id,
                                  propertyCollector: ObjectBox.FlatBufferBuilder, store: ObjectBox.Store) throws {
        let propertyOffset_eventId = propertyCollector.prepare(string: entity.eventId)
        let propertyOffset_roomKey = propertyCollector.prepare(string: entity.roomKey)
        let propertyOffset_senderPubkey = propertyCollector.prepare(string: entity.senderPubkey)
        let propertyOffset_content = propertyCollector.prepare(string: entity.content)
        let propertyOffset_replyToId = propertyCollector.prepare(string: entity.replyToId)

        propertyCollector.collect(id, at: 2 + 2 * 1)
        propertyCollector.collect(entity.createdAt, at: 2 + 2 * 6)
        propertyCollector.collect(dataOffset: propertyOffset_eventId, at: 2 + 2 * 2)
        propertyCollector.collect(dataOffset: propertyOffset_roomKey, at: 2 + 2 * 3)
        propertyCollector.collect(dataOffset: propertyOffset_senderPubkey, at: 2 + 2 * 4)
        propertyCollector.collect(dataOffset: propertyOffset_content, at: 2 + 2 * 5)
        propertyCollector.collect(dataOffset: propertyOffset_replyToId, at: 2 + 2 * 7)
    }

    internal func createEntity(entityReader: ObjectBox.FlatBufferReader, store: ObjectBox.Store) -> EntityType {
        let entity = GroupMessageEntity()

        entity.id = entityReader.read(at: 2 + 2 * 1)
        entity.eventId = entityReader.read(at: 2 + 2 * 2)
        entity.roomKey = entityReader.read(at: 2 + 2 * 3)
        entity.senderPubkey = entityReader.read(at: 2 + 2 * 4)
        entity.content = entityReader.read(at: 2 + 2 * 5)
        entity.createdAt = entityReader.read(at: 2 + 2 * 6)
        entity.replyToId = entityReader.read(at: 2 + 2 * 7)

        return entity
    }
}



nonisolated extension GroupMetaEntity: ObjectBox.__EntityRelatable {
    internal typealias EntityType = GroupMetaEntity

    internal var _id: EntityId<GroupMetaEntity> {
        return EntityId<GroupMetaEntity>(self.id.value)
    }
}

nonisolated extension GroupMetaEntity: ObjectBox.EntityInspectable {
    internal typealias EntityBindingType = GroupMetaEntityBinding

    /// Generated metadata used by ObjectBox to persist the entity.
    internal static let entityInfo = ObjectBox.EntityInfo(name: "GroupMetaEntity", id: 3)

    internal static let entityBinding = EntityBindingType()

    fileprivate static func buildEntity(modelBuilder: ObjectBox.ModelBuilder) throws {
        let entityBuilder = try modelBuilder.entityBuilder(for: GroupMetaEntity.self, id: 3, uid: 4122230795942758656)
        try entityBuilder.addProperty(name: "id", type: PropertyType.long, flags: [.id], id: 1, uid: 4626981607798092544)
        try entityBuilder.addProperty(name: "roomKey", type: PropertyType.string, flags: [.unique, .indexHash, .indexed], id: 2, uid: 1732288873423190528, indexId: 7, indexUid: 5724390025007967744)
        try entityBuilder.addProperty(name: "ownerPubkey", type: PropertyType.string, flags: [.indexHash, .indexed], id: 3, uid: 2562993484829793792, indexId: 8, indexUid: 1534493641155105792)
        try entityBuilder.addProperty(name: "relayUrl", type: PropertyType.string, id: 4, uid: 7855313476693487872)
        try entityBuilder.addProperty(name: "groupId", type: PropertyType.string, id: 5, uid: 3823594135885933056)
        try entityBuilder.addProperty(name: "name", type: PropertyType.string, id: 6, uid: 542629932493261312)
        try entityBuilder.addProperty(name: "picture", type: PropertyType.string, id: 7, uid: 8579837701980488448)
        try entityBuilder.addProperty(name: "about", type: PropertyType.string, id: 8, uid: 6791944422759577600)
        try entityBuilder.addProperty(name: "isPrivate", type: PropertyType.bool, id: 9, uid: 4010799577506342912)
        try entityBuilder.addProperty(name: "isClosed", type: PropertyType.bool, id: 10, uid: 3234619396088643584)
        try entityBuilder.addProperty(name: "isRestricted", type: PropertyType.bool, id: 11, uid: 2183834357321931008)
        try entityBuilder.addProperty(name: "isHidden", type: PropertyType.bool, id: 12, uid: 8898084865607896832)
        try entityBuilder.addProperty(name: "adminsJson", type: PropertyType.string, id: 13, uid: 4808034248163573248)
        try entityBuilder.addProperty(name: "membersJson", type: PropertyType.string, id: 14, uid: 279795950941557504)
        try entityBuilder.addProperty(name: "lastMessageAt", type: PropertyType.long, id: 15, uid: 4060783617180157440)

        try entityBuilder.lastProperty(id: 15, uid: 4060783617180157440)
    }
}

nonisolated extension GroupMetaEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.id == myId }
    internal static var id: Property<GroupMetaEntity, Id, Id> { return Property<GroupMetaEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.roomKey.startsWith("X") }
    internal static var roomKey: Property<GroupMetaEntity, String, Void> { return Property<GroupMetaEntity, String, Void>(propertyId: 2, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.ownerPubkey.startsWith("X") }
    internal static var ownerPubkey: Property<GroupMetaEntity, String, Void> { return Property<GroupMetaEntity, String, Void>(propertyId: 3, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.relayUrl.startsWith("X") }
    internal static var relayUrl: Property<GroupMetaEntity, String, Void> { return Property<GroupMetaEntity, String, Void>(propertyId: 4, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.groupId.startsWith("X") }
    internal static var groupId: Property<GroupMetaEntity, String, Void> { return Property<GroupMetaEntity, String, Void>(propertyId: 5, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.name.startsWith("X") }
    internal static var name: Property<GroupMetaEntity, String?, Void> { return Property<GroupMetaEntity, String?, Void>(propertyId: 6, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.picture.startsWith("X") }
    internal static var picture: Property<GroupMetaEntity, String?, Void> { return Property<GroupMetaEntity, String?, Void>(propertyId: 7, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.about.startsWith("X") }
    internal static var about: Property<GroupMetaEntity, String?, Void> { return Property<GroupMetaEntity, String?, Void>(propertyId: 8, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.isPrivate == true }
    internal static var isPrivate: Property<GroupMetaEntity, Bool, Void> { return Property<GroupMetaEntity, Bool, Void>(propertyId: 9, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.isClosed == true }
    internal static var isClosed: Property<GroupMetaEntity, Bool, Void> { return Property<GroupMetaEntity, Bool, Void>(propertyId: 10, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.isRestricted == true }
    internal static var isRestricted: Property<GroupMetaEntity, Bool, Void> { return Property<GroupMetaEntity, Bool, Void>(propertyId: 11, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.isHidden == true }
    internal static var isHidden: Property<GroupMetaEntity, Bool, Void> { return Property<GroupMetaEntity, Bool, Void>(propertyId: 12, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.adminsJson.startsWith("X") }
    internal static var adminsJson: Property<GroupMetaEntity, String, Void> { return Property<GroupMetaEntity, String, Void>(propertyId: 13, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.membersJson.startsWith("X") }
    internal static var membersJson: Property<GroupMetaEntity, String, Void> { return Property<GroupMetaEntity, String, Void>(propertyId: 14, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { GroupMetaEntity.lastMessageAt > 1234 }
    internal static var lastMessageAt: Property<GroupMetaEntity, Int, Void> { return Property<GroupMetaEntity, Int, Void>(propertyId: 15, isPrimaryKey: false) }

    fileprivate func __setId(identifier: ObjectBox.Id) {
        self.id = Id(identifier)
    }
}

nonisolated extension ObjectBox.Property where E == GroupMetaEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .id == myId }

    internal static var id: Property<GroupMetaEntity, Id, Id> { return Property<GroupMetaEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .roomKey.startsWith("X") }

    internal static var roomKey: Property<GroupMetaEntity, String, Void> { return Property<GroupMetaEntity, String, Void>(propertyId: 2, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .ownerPubkey.startsWith("X") }

    internal static var ownerPubkey: Property<GroupMetaEntity, String, Void> { return Property<GroupMetaEntity, String, Void>(propertyId: 3, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .relayUrl.startsWith("X") }

    internal static var relayUrl: Property<GroupMetaEntity, String, Void> { return Property<GroupMetaEntity, String, Void>(propertyId: 4, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .groupId.startsWith("X") }

    internal static var groupId: Property<GroupMetaEntity, String, Void> { return Property<GroupMetaEntity, String, Void>(propertyId: 5, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .name.startsWith("X") }

    internal static var name: Property<GroupMetaEntity, String?, Void> { return Property<GroupMetaEntity, String?, Void>(propertyId: 6, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .picture.startsWith("X") }

    internal static var picture: Property<GroupMetaEntity, String?, Void> { return Property<GroupMetaEntity, String?, Void>(propertyId: 7, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .about.startsWith("X") }

    internal static var about: Property<GroupMetaEntity, String?, Void> { return Property<GroupMetaEntity, String?, Void>(propertyId: 8, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .isPrivate == true }

    internal static var isPrivate: Property<GroupMetaEntity, Bool, Void> { return Property<GroupMetaEntity, Bool, Void>(propertyId: 9, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .isClosed == true }

    internal static var isClosed: Property<GroupMetaEntity, Bool, Void> { return Property<GroupMetaEntity, Bool, Void>(propertyId: 10, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .isRestricted == true }

    internal static var isRestricted: Property<GroupMetaEntity, Bool, Void> { return Property<GroupMetaEntity, Bool, Void>(propertyId: 11, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .isHidden == true }

    internal static var isHidden: Property<GroupMetaEntity, Bool, Void> { return Property<GroupMetaEntity, Bool, Void>(propertyId: 12, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .adminsJson.startsWith("X") }

    internal static var adminsJson: Property<GroupMetaEntity, String, Void> { return Property<GroupMetaEntity, String, Void>(propertyId: 13, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .membersJson.startsWith("X") }

    internal static var membersJson: Property<GroupMetaEntity, String, Void> { return Property<GroupMetaEntity, String, Void>(propertyId: 14, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .lastMessageAt > 1234 }

    internal static var lastMessageAt: Property<GroupMetaEntity, Int, Void> { return Property<GroupMetaEntity, Int, Void>(propertyId: 15, isPrimaryKey: false) }

}


/// Generated service type to handle persisting and reading entity data. Exposed through `GroupMetaEntity.EntityBindingType`.
nonisolated internal final class GroupMetaEntityBinding: ObjectBox.EntityBinding, Sendable {
    internal typealias EntityType = GroupMetaEntity
    internal typealias IdType = Id

    internal required init() {}

    internal func generatorBindingVersion() -> Int { 1 }

    internal func setEntityIdUnlessStruct(of entity: EntityType, to entityId: ObjectBox.Id) {
        entity.__setId(identifier: entityId)
    }

    internal func entityId(of entity: EntityType) -> ObjectBox.Id {
        return entity.id.value
    }

    internal func collect(fromEntity entity: EntityType, id: ObjectBox.Id,
                                  propertyCollector: ObjectBox.FlatBufferBuilder, store: ObjectBox.Store) throws {
        let propertyOffset_roomKey = propertyCollector.prepare(string: entity.roomKey)
        let propertyOffset_ownerPubkey = propertyCollector.prepare(string: entity.ownerPubkey)
        let propertyOffset_relayUrl = propertyCollector.prepare(string: entity.relayUrl)
        let propertyOffset_groupId = propertyCollector.prepare(string: entity.groupId)
        let propertyOffset_name = propertyCollector.prepare(string: entity.name)
        let propertyOffset_picture = propertyCollector.prepare(string: entity.picture)
        let propertyOffset_about = propertyCollector.prepare(string: entity.about)
        let propertyOffset_adminsJson = propertyCollector.prepare(string: entity.adminsJson)
        let propertyOffset_membersJson = propertyCollector.prepare(string: entity.membersJson)

        propertyCollector.collect(id, at: 2 + 2 * 1)
        propertyCollector.collect(entity.isPrivate, at: 2 + 2 * 9)
        propertyCollector.collect(entity.isClosed, at: 2 + 2 * 10)
        propertyCollector.collect(entity.isRestricted, at: 2 + 2 * 11)
        propertyCollector.collect(entity.isHidden, at: 2 + 2 * 12)
        propertyCollector.collect(entity.lastMessageAt, at: 2 + 2 * 15)
        propertyCollector.collect(dataOffset: propertyOffset_roomKey, at: 2 + 2 * 2)
        propertyCollector.collect(dataOffset: propertyOffset_ownerPubkey, at: 2 + 2 * 3)
        propertyCollector.collect(dataOffset: propertyOffset_relayUrl, at: 2 + 2 * 4)
        propertyCollector.collect(dataOffset: propertyOffset_groupId, at: 2 + 2 * 5)
        propertyCollector.collect(dataOffset: propertyOffset_name, at: 2 + 2 * 6)
        propertyCollector.collect(dataOffset: propertyOffset_picture, at: 2 + 2 * 7)
        propertyCollector.collect(dataOffset: propertyOffset_about, at: 2 + 2 * 8)
        propertyCollector.collect(dataOffset: propertyOffset_adminsJson, at: 2 + 2 * 13)
        propertyCollector.collect(dataOffset: propertyOffset_membersJson, at: 2 + 2 * 14)
    }

    internal func createEntity(entityReader: ObjectBox.FlatBufferReader, store: ObjectBox.Store) -> EntityType {
        let entity = GroupMetaEntity()

        entity.id = entityReader.read(at: 2 + 2 * 1)
        entity.roomKey = entityReader.read(at: 2 + 2 * 2)
        entity.ownerPubkey = entityReader.read(at: 2 + 2 * 3)
        entity.relayUrl = entityReader.read(at: 2 + 2 * 4)
        entity.groupId = entityReader.read(at: 2 + 2 * 5)
        entity.name = entityReader.read(at: 2 + 2 * 6)
        entity.picture = entityReader.read(at: 2 + 2 * 7)
        entity.about = entityReader.read(at: 2 + 2 * 8)
        entity.isPrivate = entityReader.read(at: 2 + 2 * 9)
        entity.isClosed = entityReader.read(at: 2 + 2 * 10)
        entity.isRestricted = entityReader.read(at: 2 + 2 * 11)
        entity.isHidden = entityReader.read(at: 2 + 2 * 12)
        entity.adminsJson = entityReader.read(at: 2 + 2 * 13)
        entity.membersJson = entityReader.read(at: 2 + 2 * 14)
        entity.lastMessageAt = entityReader.read(at: 2 + 2 * 15)

        return entity
    }
}


/// Helper function that allows calling Enum(rawValue: value) with a nil value, which will return nil.
fileprivate func optConstruct<T: RawRepresentable>(_ type: T.Type, rawValue: T.RawValue?) -> T? {
    guard let rawValue = rawValue else { return nil }
    return T(rawValue: rawValue)
}

// MARK: - Store setup

nonisolated fileprivate func cModel() throws -> OpaquePointer {
    let modelBuilder = try ObjectBox.ModelBuilder()
    try EventEntity.buildEntity(modelBuilder: modelBuilder)
    try GroupMessageEntity.buildEntity(modelBuilder: modelBuilder)
    try GroupMetaEntity.buildEntity(modelBuilder: modelBuilder)
    modelBuilder.lastEntity(id: 3, uid: 4122230795942758656)
    modelBuilder.lastIndex(id: 8, uid: 1534493641155105792)
    return modelBuilder.finish()
}

nonisolated extension ObjectBox.Store {
    /// A store with a fully configured model. Created by the code generator with your model's metadata in place.
    ///
    /// # In-memory database
    /// To use a file-less in-memory database, instead of a directory path pass `memory:` 
    /// together with an identifier string:
    /// ```swift
    /// let inMemoryStore = try Store(directoryPath: "memory:test-db")
    /// ```
    ///
    /// - Parameters:
    ///   - directoryPath: The directory path in which ObjectBox places its database files for this store,
    ///     or to use an in-memory database `memory:<identifier>`.
    ///   - maxDbSizeInKByte: Limit of on-disk space for the database files. Default is `1024 * 1024` (1 GiB).
    ///   - fileMode: UNIX-style bit mask used for the database files; default is `0o644`.
    ///     Note: directories become searchable if the "read" or "write" permission is set (e.g. 0640 becomes 0750).
    ///   - maxReaders: The maximum number of readers.
    ///     "Readers" are a finite resource for which we need to define a maximum number upfront.
    ///     The default value is enough for most apps and usually you can ignore it completely.
    ///     However, if you get the maxReadersExceeded error, you should verify your
    ///     threading. For each thread, ObjectBox uses multiple readers. Their number (per thread) depends
    ///     on number of types, relations, and usage patterns. Thus, if you are working with many threads
    ///     (e.g. in a server-like scenario), it can make sense to increase the maximum number of readers.
    ///     Note: The internal default is currently around 120. So when hitting this limit, try values around 200-500.
    ///   - readOnly: Opens the database in read-only mode, i.e. not allowing write transactions.
    ///
    /// - important: This initializer is created by the code generator. If you only see the internal `init(model:...)`
    ///              initializer, trigger code generation by building your project.
    internal convenience init(directoryPath: String, maxDbSizeInKByte: UInt64 = 1024 * 1024,
                            fileMode: UInt32 = 0o644, maxReaders: UInt32 = 0, readOnly: Bool = false) throws {
        try self.init(
            model: try cModel(),
            directory: directoryPath,
            maxDbSizeInKByte: maxDbSizeInKByte,
            fileMode: fileMode,
            maxReaders: maxReaders,
            readOnly: readOnly)
    }
}

// swiftlint:enable all
