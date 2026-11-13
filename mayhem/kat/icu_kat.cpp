// Known-answer probe for the normally-built (unsanitized) ICU: prints computed values that
// mayhem/test.sh compares against the expected golden output.
#include <cstdio>
#include <memory>
#include <string>

#include "unicode/brkiter.h"
#include "unicode/calendar.h"
#include "unicode/coll.h"
#include "unicode/datefmt.h"
#include "unicode/dtptngen.h"
#include "unicode/locid.h"
#include "unicode/normalizer2.h"
#include "unicode/numfmt.h"
#include "unicode/plurrule.h"
#include "unicode/regex.h"
#include "unicode/timezone.h"
#include "unicode/uchar.h"
#include "unicode/uloc.h"
#include "unicode/unistr.h"
#include "unicode/uscript.h"

using icu::UnicodeString;

static void out(const char* key, const UnicodeString& v) {
  std::string s;
  v.toUTF8String(s);
  std::printf("%s=%s\n", key, s.c_str());
}

int main() {
  UErrorCode st = U_ZERO_ERROR;

  out("upper", UnicodeString(u"straße").toUpper(icu::Locale::getRoot()));
  out("upper_tr", UnicodeString(u"iI").toUpper(icu::Locale("tr")));
  out("title", UnicodeString(u"hello wORLD").toTitle(nullptr, icu::Locale::getEnglish()));

  const icu::Normalizer2* nfc = icu::Normalizer2::getNFCInstance(st);
  const icu::Normalizer2* nfkc = icu::Normalizer2::getNFKCInstance(st);
  const icu::Normalizer2* nfd = icu::Normalizer2::getNFDInstance(st);
  UnicodeString r;
  nfc->normalize(UnicodeString(u"é"), r, st);
  std::printf("nfc_len=%d nfc_cp=%04X\n", r.length(), (unsigned)r.char32At(0));
  nfkc->normalize(UnicodeString(u"ﬁ"), r, st);
  out("nfkc", r);
  nfd->normalize(UnicodeString(u"é"), r, st);
  std::printf("nfd_len=%d\n", r.length());

  std::unique_ptr<icu::Collator> en(icu::Collator::createInstance(icu::Locale::getEnglish(), st));
  std::unique_ptr<icu::Collator> sv(icu::Collator::createInstance(icu::Locale("sv"), st));
  std::printf("coll_en=%d %d\n", (int)en->compare(UnicodeString(u"a"), UnicodeString(u"B"), st),
              (int)en->compare(UnicodeString(u"b"), UnicodeString(u"A"), st));
  std::printf("coll_sv=%d\n", (int)sv->compare(UnicodeString(u"z"), UnicodeString(u"ö"), st));
  std::printf("coll_en_z_o=%d\n", (int)en->compare(UnicodeString(u"z"), UnicodeString(u"ö"), st));

  UnicodeString num;
  std::unique_ptr<icu::NumberFormat> nf_us(icu::NumberFormat::createInstance(icu::Locale::getUS(), st));
  std::unique_ptr<icu::NumberFormat> nf_de(icu::NumberFormat::createInstance(icu::Locale::getGermany(), st));
  nf_us->format(1234567.891, num);
  out("num_us", num);
  num.remove();
  nf_de->format(1234567.891, num);
  out("num_de", num);

  std::unique_ptr<icu::TimeZone> utc(icu::TimeZone::createTimeZone("UTC"));
  std::unique_ptr<icu::DateFormat> df(
      icu::DateFormat::createDateTimeInstance(icu::DateFormat::kMedium, icu::DateFormat::kMedium,
                                              icu::Locale::getUS()));
  df->setTimeZone(*utc);
  UnicodeString ds;
  df->format((UDate)86400000.0 * 365, ds);
  out("date_us", ds);
  std::unique_ptr<icu::DateTimePatternGenerator> gen(
      icu::DateTimePatternGenerator::createInstance(icu::Locale::getUS(), st));
  out("skeleton_yMd_us", gen->getBestPattern(UnicodeString(u"yMd"), st));
  std::unique_ptr<icu::DateTimePatternGenerator> gen_de(
      icu::DateTimePatternGenerator::createInstance(icu::Locale::getGermany(), st));
  out("skeleton_yMd_de", gen_de->getBestPattern(UnicodeString(u"yMd"), st));

  std::unique_ptr<icu::Calendar> cal(icu::Calendar::createInstance(*utc, icu::Locale::getUS(), st));
  cal->setTime((UDate)0, st);
  std::printf("cal=%d-%d-%d dow=%d\n", cal->get(UCAL_YEAR, st), cal->get(UCAL_MONTH, st) + 1,
              cal->get(UCAL_DATE, st), cal->get(UCAL_DAY_OF_WEEK, st));

  std::unique_ptr<icu::BreakIterator> wb(
      icu::BreakIterator::createWordInstance(icu::Locale::getUS(), st));
  UnicodeString text(u"Hello, world! It's 3.14.");
  wb->setText(text);
  int words = 0;
  int32_t p = wb->first();
  for (p = wb->next(); p != icu::BreakIterator::DONE; p = wb->next()) ++words;
  std::printf("word_segments=%d\n", words);
  std::unique_ptr<icu::BreakIterator> sb(
      icu::BreakIterator::createSentenceInstance(icu::Locale::getUS(), st));
  UnicodeString stext(u"One. Two? Three!");
  sb->setText(stext);
  int sentences = 0;
  sb->first();
  for (p = sb->next(); p != icu::BreakIterator::DONE; p = sb->next()) ++sentences;
  std::printf("sentences=%d\n", sentences);

  std::unique_ptr<icu::PluralRules> pr(icu::PluralRules::forLocale(icu::Locale("ru"), st));
  std::string pl;
  for (int n : {1, 2, 5, 21}) {
    UnicodeString k = pr->select(n);
    std::string s;
    k.toUTF8String(s);
    pl += s + (n == 21 ? "" : ",");
  }
  std::printf("plural_ru=%s\n", pl.c_str());

  UnicodeString haystack(u"x 42-abc y");
  icu::RegexMatcher m(UnicodeString(u"(\\d+)-(\\p{L}+)"), haystack, 0, st);
  if (m.find(st)) {
    out("re_g1", m.group(1, st));
    out("re_g2", m.group(2, st));
  }

  char buf[64];
  uloc_canonicalize("en_us_posix", buf, sizeof buf, &st);
  std::printf("canon=%s\n", buf);
  uloc_forLanguageTag("zh-Hant-TW-u-ca-roc", buf, sizeof buf, nullptr, &st);
  std::printf("langtag=%s\n", buf);
  uloc_addLikelySubtags("sr", buf, sizeof buf, &st);
  std::printf("likely=%s\n", buf);
  std::printf("rtl=%d,%d\n", (int)uloc_isRightToLeft("ar"), (int)uloc_isRightToLeft("en"));
  std::printf("uchar=%d %d %d\n", (int)u_charType(0x41), (int)u_isalpha(0x4e2d), (int)uscript_getScript(0x4e2d, &st));
  std::printf("status=%s\n", u_errorName(st));
  return 0;
}
