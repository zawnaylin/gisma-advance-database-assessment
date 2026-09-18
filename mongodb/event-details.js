// MongoDB companion to the Postgres schema in sql-files/create-tables.sql.
//
// event_details holds the category-specific content for an event that a
// fixed relational column set handles poorly: a concert has an artist, a
// conference has a list of speakers, a sports fixture has teams -- three
// unrelated shapes for "the interesting bit about this event." Modeling
// that in Postgres means either a wide table full of columns that are NULL
// for every category but one, or a separate table per category joined back
// to events. Here it's just `attributes`, an object whose shape isn't
// declared up front -- see docs/erd.mmd for how this sits next to the SQL
// schema (EVENTS ||--o| EVENT_DETAILS, an application-enforced link only,
// not a real foreign key -- no engine on either side can check it).
//
// Run with: mongosh <connection-string> mongodb/event-details.js

// =============================================================================
// createCollection, with schema validation
// =============================================================================
// The $jsonSchema lives in mongodb/event-details.schema.json, shared with
// scripts/sync-event-details.ts so the two can't drift apart. Note that
// `attributes` is deliberately NOT shaped beyond "must be an object" -- this
// is the field the whole collection exists for. Validating its inner fields
// would just recreate the rigid-schema problem one level down.
//
// Skipped if the collection already exists (e.g. the sync script created it).
const eventDetailsSchema = JSON.parse(require("fs").readFileSync("mongodb/event-details.schema.json", "utf8"));

if (!db.getCollectionNames().includes("event_details")) {
    db.createCollection("event_details", { validator: { $jsonSchema: eventDetailsSchema } });
}

// One event has at most one details document -- mirrors the EVENTS ||--o|
// EVENT_DETAILS cardinality in the ERD, and is the closest thing to that
// relationship MongoDB can actually enforce (uniqueness, not existence of
// the referenced row -- that part really is on the application).
db.event_details.createIndex({ sql_event_id: 1 }, { unique: true });
db.event_details.createIndex({ category: 1 });
db.event_details.createIndex({ tags: 1 });

// =============================================================================
// CREATE
// =============================================================================

// Meant to be run against an EMPTY collection. If scripts/sync-event-details.ts
// has already seeded it, sql_event_id 1 exists and the unique index rejects
// the insert (E11000) -- warn and carry on rather than aborting, so the rest
// of the walkthrough still runs against the existing document. Any other
// error is real and still stops the script.
function insertDemoDoc(doc) {
    try {
        db.event_details.insertOne(doc);
    } catch (e) {
        if (e.code !== 11000) throw e;
        print(`warning: event_details already has sql_event_id ${doc.sql_event_id} -- skipped inserting "${doc.title}" (run on an empty collection to see this step)`);
    }
}

insertDemoDoc({
    sql_event_id: 1, // Waterfront Arena / Autumn Jazz Night, per the Postgres seed data
    title: "Autumn Jazz Night",
    category: "concert",
    description: "An intimate evening of modern jazz standards.",
    tags: ["jazz", "live-band", "evening"],
    attributes: {
        artist: "The Harbor Quartet",
        support_act: "Nora Lindqvist Trio",
        genre: "jazz"
    },
    media: {
        poster_url: "https://cdn.example.com/events/autumn-jazz-night.jpg",
        gallery: []
    },
    created_at: new Date(),
    updated_at: new Date()
});

// A different category, a completely different attributes shape -- same
// collection, same validator, no schema migration needed to add this.
insertDemoDoc({
    sql_event_id: 12,
    title: "Data Systems Summit",
    category: "conference",
    description: "A one-day summit on distributed data infrastructure.",
    tags: ["tech", "databases", "conference"],
    attributes: {
        speakers: ["Dr. Amara Okafor", "Jonas Weber", "Priya Nair"],
        tracks: ["Storage Engines", "Query Optimization", "Distributed Systems"]
    },
    media: {
        poster_url: "https://cdn.example.com/events/data-systems-summit.jpg",
        gallery: ["https://cdn.example.com/events/dss/hall.jpg"]
    },
    created_at: new Date(),
    updated_at: new Date()
});

// =============================================================================
// READ
// =============================================================================

// One event's details, by the reference back to Postgres.
db.event_details.findOne({ sql_event_id: 1 });

// Every concert, title + artist only.
db.event_details.find(
    { category: "concert" },
    { title: 1, "attributes.artist": 1, _id: 0 }
);

// Anything tagged "jazz".
db.event_details.find({ tags: "jazz" });

// =============================================================================
// UPDATE
// =============================================================================

// Add a field inside attributes -- no migration, no ALTER TABLE, just a
// $set on whatever path this category happens to use. This is the same
// operation Postgres would need a new nullable column (or a JSONB column)
// for; here it's the collection's normal shape.
db.event_details.updateOne(
    { sql_event_id: 1 },
    {
        $set: { "attributes.venue_notes": "General admission standing area near the stage.", updated_at: new Date() }
    }
);

// Append a tag without re-reading the array first.
db.event_details.updateOne(
    { sql_event_id: 1 },
    {
        $push: { tags: "standing-room" },
        $set: { updated_at: new Date() }
    }
);

// Worth noting explicitly: unlike set_updated_at() in the Postgres schema,
// there's no trigger here -- updated_at only advances because every UPDATE
// above sets it by hand. Skip that $set and the field goes stale. Getting
// trigger-like behavior in MongoDB means enforcing it in the application
// layer, or reaching for change streams -- there's no BEFORE UPDATE
// equivalent built into a plain query.

// =============================================================================
// DELETE
// =============================================================================
// Matched on title as well as sql_event_id: on a seeded collection, id 12 is
// a real event's details document, and the demo insert above was skipped --
// this should only ever remove the demo's own document, never seeded data.
db.event_details.deleteOne({ sql_event_id: 12, title: "Data Systems Summit" });

// =============================================================================
// AGGREGATION 1 -- normalize the category-specific "headline" field
// =============================================================================
// The whole point of `attributes` is that it varies by category -- but a
// UI listing page usually wants ONE consistent "what's the highlight"
// field regardless of category. $switch pulls that out at query time
// instead of needing a UI branch (or a relational table) per category.
//
// And the shape varies WITHIN a category too: a concert can be one artist,
// a festival lineup or an orchestra. So each branch is an $ifNull chain --
// the first of these fields the document actually has wins, and a missing
// field (or $arrayElemAt on a missing array) just falls through to the next.
const firstOf = (arrayPath) => ({ $arrayElemAt: [arrayPath, 0] });

db.event_details.aggregate([
    {
        $project: {
            _id: 0,
            sql_event_id: 1,
            title: 1,
            category: 1,
            highlight: {
                $switch: {
                    branches: [
                        {
                            // single act -> festival headliner -> orchestra/ensemble
                            case: { $eq: ["$category", "concert"] },
                            then: {
                                $ifNull: ["$attributes.artist", firstOf("$attributes.lineup"),
                                    "$attributes.ensemble", null]
                            }
                        },
                        {
                            // opera composer -> playwright -> lead cast member. An opera's
                            // cast is [{ role, performer }], a play's is plain names, so
                            // take .performer if the first entry has one, else the entry.
                            case: { $eq: ["$category", "theatre"] },
                            then: {
                                $ifNull: ["$attributes.composer", "$attributes.playwright",
                                    {
                                        $let: {
                                            vars: { lead: firstOf("$attributes.cast") },
                                            in: { $ifNull: ["$$lead.performer", "$$lead"] }
                                        }
                                    },
                                    null]
                            }
                        },
                        {
                            // first-billed comic -> host
                            case: { $eq: ["$category", "comedy"] },
                            then: { $ifNull: [firstOf("$attributes.performers"), "$attributes.host", null] }
                        },
                        { case: { $eq: ["$category", "conference"] }, then: firstOf("$attributes.speakers") },
                        { case: { $eq: ["$category", "sports"] }, then: "$attributes.teams" }
                    ],
                    default: null
                }
            }
        }
    },
    { $sort: { sql_event_id: 1 } }
]);

// =============================================================================
// AGGREGATION 2 -- top tags across all events (a tag cloud)
// =============================================================================
db.event_details.aggregate([
    { $unwind: "$tags" },
    { $group: { _id: "$tags", event_count: { $sum: 1 } } },
    { $sort: { event_count: -1 } },
    { $limit: 5 }
]);
