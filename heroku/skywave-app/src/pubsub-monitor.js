// Globe-monitor Pub/Sub subscriber — ISOLATED from the consumer path.
//
// Subscribes to the Demo_Event__e visitor firehose (session_started,
// profile_created, survey_answer, flight_booked, seat_changed, …) on its OWN
// Pub/Sub instance and broadcasts each event ONLY to /ws/monitor sockets. The
// consumer phones are on a separate subscriber (Demo_State_Change__e) and a
// separate socket registry — they never receive this firehose.
//
// The decoded event maps straight to the Demo_Event__e-shaped PlatformEventPayload
// the globe's visitorReducer already folds (Type__c / Session_Id__c /
// Payload_Json__c / Demo_Session_Id__c), so no transformation is needed
// browser-side.

import { createPubSubSubscriber, unwrap } from './pubsub-client.js';

const monitor = createPubSubSubscriber({
    topic: '/event/Demo_Event__e',
    mapEvent: (decoded, replayId) => ({
        Type__c: unwrap(decoded.Type__c),
        Session_Id__c: unwrap(decoded.Session_Id__c),
        Payload_Json__c: unwrap(decoded.Payload_Json__c),
        Demo_Session_Id__c: unwrap(decoded.Demo_Session_Id__c),
        replayId
    })
});

export const startMonitorSubscriber = monitor.start;
export const getMonitorStatus = monitor.getStatus;
