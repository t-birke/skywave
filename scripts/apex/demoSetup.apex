Map<String, Object> results = DemoSetup.run();
for (String step : results.keySet()) {
    System.debug(step + ': ' + results.get(step));
}
