/**
 * Factory class for creating demo data for Skywave Airlines
 * Used by demo data scripts
 */
public class GenerateDemoData {
    
    /**
     * Creates a single contact: Lauren Bailey with Gold tier
     */
    public static List<Contact> createContacts() {
        List<Contact> contacts = new List<Contact>();
        
        Contact lauren = new Contact();
        lauren.FirstName = 'Lauren';
        lauren.LastName = 'Bailey';
        lauren.Email = 'lauren.bailey@example.com';
        lauren.Membership_Tier__c = 'Gold';
        lauren.Member_Number__c = 'SW1000000';
        lauren.Loyalty_Points__c = 15000;
        lauren.Membership_Start_Date__c = Date.today().addYears(-2);
        contacts.add(lauren);
        
        return contacts;
    }
    
    /**
     * Creates sample flights in the master schedule
     */
    public static List<Flight__c> createFlights() {
        List<Flight__c> flights = new List<Flight__c>();
        
        // Define major routes
        List<Map<String, Object>> routes = new List<Map<String, Object>>{
            new Map<String, Object>{
                'number' => 'SW1001',
                'origin' => 'SEA',
                'destination' => 'JFK',
                'deptTime' => Time.newInstance(6, 30, 0, 0),
                'arrivalTime' => Time.newInstance(14, 50, 0, 0),
                'duration' => 320,
                'aircraft' => 'Boeing 737-800',
                'days' => new List<String>{'Monday', 'Wednesday', 'Friday'}
            },
            new Map<String, Object>{
                'number' => 'SW1002',
                'origin' => 'JFK',
                'destination' => 'SEA',
                'deptTime' => Time.newInstance(16, 0, 0, 0),
                'arrivalTime' => Time.newInstance(19, 30, 0, 0),
                'duration' => 330,
                'aircraft' => 'Boeing 737-800',
                'days' => new List<String>{'Monday', 'Wednesday', 'Friday'}
            },
            new Map<String, Object>{
                'number' => 'SW2101',
                'origin' => 'LAX',
                'destination' => 'ORD',
                'deptTime' => Time.newInstance(8, 0, 0, 0),
                'arrivalTime' => Time.newInstance(14, 15, 0, 0),
                'duration' => 255,
                'aircraft' => 'Airbus A320',
                'days' => new List<String>{'Tuesday', 'Thursday', 'Saturday'}
            },
            new Map<String, Object>{
                'number' => 'SW2102',
                'origin' => 'ORD',
                'destination' => 'LAX',
                'deptTime' => Time.newInstance(15, 30, 0, 0),
                'arrivalTime' => Time.newInstance(18, 0, 0, 0),
                'duration' => 270,
                'aircraft' => 'Airbus A320',
                'days' => new List<String>{'Tuesday', 'Thursday', 'Saturday'}
            },
            new Map<String, Object>{
                'number' => 'SW3201',
                'origin' => 'DFW',
                'destination' => 'MIA',
                'deptTime' => Time.newInstance(9, 15, 0, 0),
                'arrivalTime' => Time.newInstance(13, 0, 0, 0),
                'duration' => 165,
                'aircraft' => 'Boeing 737-900',
                'days' => new List<String>{'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'}
            },
            new Map<String, Object>{
                'number' => 'SW3202',
                'origin' => 'MIA',
                'destination' => 'DFW',
                'deptTime' => Time.newInstance(14, 30, 0, 0),
                'arrivalTime' => Time.newInstance(16, 45, 0, 0),
                'duration' => 195,
                'aircraft' => 'Boeing 737-900',
                'days' => new List<String>{'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'}
            },
            new Map<String, Object>{
                'number' => 'SW4301',
                'origin' => 'BOS',
                'destination' => 'SFO',
                'deptTime' => Time.newInstance(7, 0, 0, 0),
                'arrivalTime' => Time.newInstance(10, 45, 0, 0),
                'duration' => 405,
                'aircraft' => 'Airbus A321',
                'days' => new List<String>{'Sunday', 'Wednesday', 'Saturday'}
            },
            new Map<String, Object>{
                'number' => 'SW4302',
                'origin' => 'SFO',
                'destination' => 'BOS',
                'deptTime' => Time.newInstance(12, 30, 0, 0),
                'arrivalTime' => Time.newInstance(21, 0, 0, 0),
                'duration' => 390,
                'aircraft' => 'Airbus A321',
                'days' => new List<String>{'Sunday', 'Wednesday', 'Saturday'}
            }
        };
        
        for (Map<String, Object> route : routes) {
            Flight__c f = new Flight__c();
            f.Name = (String)route.get('number');
            f.Flight_Number__c = (String)route.get('number');
            f.Origin__c = (String)route.get('origin');
            f.Destination__c = (String)route.get('destination');
            f.Scheduled_Departure_Time__c = (Time)route.get('deptTime');
            f.Scheduled_Arrival_Time__c = (Time)route.get('arrivalTime');
            f.Duration_Minutes__c = (Integer)route.get('duration');
            f.Aircraft_Type__c = (String)route.get('aircraft');
            f.Active__c = true;
            
            // Set operating days
            List<String> operatingDays = (List<String>)route.get('days');
            f.Operates_Monday__c = operatingDays.contains('Monday');
            f.Operates_Tuesday__c = operatingDays.contains('Tuesday');
            f.Operates_Wednesday__c = operatingDays.contains('Wednesday');
            f.Operates_Thursday__c = operatingDays.contains('Thursday');
            f.Operates_Friday__c = operatingDays.contains('Friday');
            f.Operates_Saturday__c = operatingDays.contains('Saturday');
            f.Operates_Sunday__c = operatingDays.contains('Sunday');
            
            // Set pricing (random variation for realism)
            Decimal basePrice = 200 + Math.random() * 300;
            f.Base_Price_Economy__c = basePrice;
            f.Base_Price_Premium_Economy__c = basePrice * 1.9;
            f.Base_Price_Business__c = basePrice * 4.3;
            f.Base_Price_First__c = basePrice * 7.0;
            
            flights.add(f);
        }
        
        return flights;
    }
    
    /**
     * Creates sample bookings with segments for testing
     */
    public static List<Booking__c> createBookings(List<Contact> contacts, List<Flight__c> flights, Integer bookingsPerContact) {
        List<Booking__c> bookings = new List<Booking__c>();
        List<String> fareClasses = new List<String>{'Economy', 'Premium Economy', 'Business', 'First'};

        Integer bookingCount = 0;
        for (Contact c : contacts) {
            for (Integer i = 0; i < bookingsPerContact; i++) {
                Booking__c b = new Booking__c();
                b.Contact__c = c.Id;
                b.Confirmation_Code__c = generateConfirmationCode(bookingCount);
                b.Status__c = 'Confirmed';
                b.Fare_Class__c = fareClasses[Math.mod(i, fareClasses.size())];
                b.Checked_Bags__c = Math.mod(i, 3);
                b.Booking_Date__c = Date.today().addDays(-30 + Math.mod(bookingCount, 60));

                // Calculate price based on fare class
                Flight__c flight = flights[Math.mod(bookingCount, flights.size())];
                if (b.Fare_Class__c == 'Economy') {
                    b.Total_Amount__c = flight.Base_Price_Economy__c;
                } else if (b.Fare_Class__c == 'Premium Economy') {
                    b.Total_Amount__c = flight.Base_Price_Premium_Economy__c;
                } else if (b.Fare_Class__c == 'Business') {
                    b.Total_Amount__c = flight.Base_Price_Business__c;
                } else {
                    b.Total_Amount__c = flight.Base_Price_First__c;
                }

                bookings.add(b);
                bookingCount++;
            }
        }

        return bookings;
    }

    /**
     * Creates booking segments for existing bookings
     */
    public static List<Booking_Segment__c> createBookingSegments(List<Booking__c> bookings, List<Flight__c> flights) {
        List<Booking_Segment__c> segments = new List<Booking_Segment__c>();

        for (Integer i = 0; i < bookings.size(); i++) {
            Booking__c booking = bookings[i];
            Flight__c flight = flights[Math.mod(i, flights.size())];

            // Create travel date within the next 72 hours (1-3 days from now)
            Date travelDate = Date.today().addDays(1 + Math.mod(i, 3));

            // Calculate departure and arrival DateTimes
            DateTime departureDateTime = DateTime.newInstance(travelDate, flight.Scheduled_Departure_Time__c);
            DateTime arrivalDateTime = DateTime.newInstance(travelDate, flight.Scheduled_Arrival_Time__c);

            // Handle overnight flights
            if (flight.Scheduled_Arrival_Time__c < flight.Scheduled_Departure_Time__c) {
                arrivalDateTime = arrivalDateTime.addDays(1);
            }

            Booking_Segment__c seg = new Booking_Segment__c();
            seg.Booking__c = booking.Id;
            seg.Flight__c = flight.Id;
            seg.Travel_Date__c = travelDate;
            seg.Departure_DateTime__c = departureDateTime;
            seg.Arrival_DateTime__c = arrivalDateTime;
            seg.Segment_Order__c = 1;
            seg.Segment_Status__c = 'Scheduled';
            seg.Seat_Number__c = generateSeatNumber(i);

            segments.add(seg);
        }

        return segments;
    }
    
    /**
     * Generates a unique confirmation code
     */
    private static String generateConfirmationCode(Integer seed) {
        String chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        String code = '';
        
        for (Integer i = 0; i < 6; i++) {
            Integer index = Math.mod(seed * (i + 1) * 37, chars.length());
            code += chars.substring(index, index + 1);
        }
        
        return code;
    }
    
    /**
     * Generates a seat number
     */
    private static String generateSeatNumber(Integer seed) {
        Integer row = 10 + Math.mod(seed, 20);
        List<String> seats = new List<String>{'A', 'B', 'C', 'D', 'E', 'F'};
        String seat = seats[Math.mod(seed, seats.size())];
        return String.valueOf(row) + seat;
    }
}