/**
 * Renderer DTO for the Skywave Seat Map custom Lightning Type.
 *
 * Single @AuraEnabled String holds JSON: bookingSegmentId + bookingCode +
 * flightNumber + aircraftType + currentSeat + a cosmetic seat grid (rows of
 * seats, each flagged available / taken / current). The LWC parses it, lets
 * the visitor pick an open seat, and on "Confirm seat" calls
 * Skywave_ChangeSeat.confirmSeatChange imperatively to persist the choice.
 *
 * Pattern B (JSON envelope) — same shape as Skywave_PaymentFormData.
 */
@JsonAccess(serializable='always' deserializable='always')
global class Skywave_SeatMapData {

    @AuraEnabled
    global String seatMapJSON;

    global Skywave_SeatMapData(String seatMapJSON) {
        this.seatMapJSON = seatMapJSON;
    }

    global Skywave_SeatMapData() {
        this.seatMapJSON = '';
    }
}
