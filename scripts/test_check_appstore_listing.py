import unittest

from check_appstore_listing import check

FENCE = "`" * 3


def field(name, limit, text):
    return f"### {name} (max {limit})\n\n{FENCE}text\n{text}\n{FENCE}\n"


class CheckTests(unittest.TestCase):
    def test_fields_within_limits_pass(self):
        md = field("Subtitle", 30, "Local AI images on your Mac") + field("Keywords", 100, "flux,mlx")
        self.assertEqual(check(md), [])

    def test_an_over_limit_field_is_reported_with_its_length(self):
        problems = check(field("Subtitle", 30, "x" * 31))
        self.assertEqual(problems, ["Subtitle: 31 characters, max 30"])

    def test_characters_not_bytes_are_counted(self):
        self.assertEqual(check(field("Name", 5, "café…")), [])

    def test_a_heading_without_a_block_is_reported(self):
        self.assertEqual(check("### Subtitle (max 30)\n\nno block here\n"), ["Subtitle: no text block"])

    def test_keywords_must_not_have_spaces_after_commas(self):
        self.assertEqual(check(field("Keywords", 100, "flux, mlx")), ["Keywords: space after a comma wastes a character"])


if __name__ == "__main__":
    unittest.main()
