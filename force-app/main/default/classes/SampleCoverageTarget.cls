public with sharing class SampleCoverageTarget {
	public static Integer sumPositiveValues(List<Integer> values) {
		if (values == null || values.isEmpty()) {
			return 0;
		}

		Integer total = 0;
		for (Integer value : values) {
			if (value != null && value > 0) {
				total += value;
			}
		}
		return total;
	}

	public static String classifyScore(Integer score) {
		if (score == null) {
			return 'No Score';
		}
		if (score >= 90) {
			return 'Excellent';
		}
		if (score >= 75) {
			return 'Good';
		}
		if (score >= 50) {
			return 'Needs Review';
		}
		return 'At Risk';
	}
}