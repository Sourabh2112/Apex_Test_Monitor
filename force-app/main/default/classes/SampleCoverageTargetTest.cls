@IsTest
private class SampleCoverageTargetTest {
    @IsTest
    static void sumPositiveValuesIgnoresNullsAndNegatives() {
        Integer result = SampleCoverageTarget.sumPositiveValues(new List<Integer>{ 10, -5, null, 7, 0 });

        System.assertEquals(17, result);
    }

    @IsTest
    static void classifyScoreCoversCommonOutcomes() {
        System.assertEquals('Excellent', SampleCoverageTarget.classifyScore(95));
        System.assertEquals('Good', SampleCoverageTarget.classifyScore(80));
        System.assertEquals('Needs Review', SampleCoverageTarget.classifyScore(60));
    }
}
