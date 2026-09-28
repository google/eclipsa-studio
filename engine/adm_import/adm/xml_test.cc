// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "adm_import/adm/xml.h"

#include <string>

#include "gtest/gtest.h"

namespace adm2iamf {
namespace {

TEST(Xml, ParsesAttributesTextAndChildren) {
  const std::string doc = R"(<?xml version="1.0" encoding="UTF-8"?>
    <!-- a comment -->
    <root xmlns:adm="urn:x">
      <adm:item id="a" n="1">text-a</adm:item>
      <item id="b">text-b</item>
      <empty/>
    </root>)";
  auto root = ParseXml(doc);
  ASSERT_TRUE(root.ok()) << root.status();
  EXPECT_EQ(root->name, "root");

  auto items = root->Children("item");
  ASSERT_EQ(items.size(), 2u);  // Namespace prefix stripped on first.
  EXPECT_EQ(*items[0]->Attr("id"), "a");
  EXPECT_EQ(items[0]->AttrOr("n", "?"), "1");
  EXPECT_EQ(items[0]->text, "text-a");
  EXPECT_EQ(items[1]->text, "text-b");
  EXPECT_EQ(root->AttrOr("missing", "def"), "def");

  ASSERT_NE(root->Child("empty"), nullptr);
  EXPECT_TRUE(root->Child("empty")->text.empty());
}

TEST(Xml, DecodesEntitiesAndCdata) {
  const std::string doc =
      "<r><a>5 &lt; 10 &amp; ok</a><b><![CDATA[<raw> & ]]></b>"
      "<c>&#65;&#x42;</c></r>";
  auto root = ParseXml(doc);
  ASSERT_TRUE(root.ok()) << root.status();
  EXPECT_EQ(root->Child("a")->text, "5 < 10 & ok");
  // Leaf text is trimmed (ADM values like "30.0" come out clean); the CDATA's
  // trailing space is dropped accordingly.
  EXPECT_EQ(root->Child("b")->text, "<raw> &");
  EXPECT_EQ(root->Child("c")->text, "AB");
}

TEST(Xml, NumericCharRefsAreValidatedAgainstUntrustedInput) {
  // Valid refs decode; invalid ones (overflow, surrogate, NUL, non-digit,
  // empty) are kept verbatim rather than emitting malformed UTF-8.
  const std::string doc =
      "<r>"
      "<ok>&#233;</ok>"               // e-acute (U+00E9) -> 2-byte UTF-8
      "<over>&#999999999999;</over>"  // overflows past U+10FFFF
      "<surr>&#xD800;</surr>"         // UTF-16 surrogate
      "<nul>&#0;</nul>"               // disallowed NUL
      "<bad>&#1g;</bad>"              // non-digit in a decimal ref
      "<empty>&#;</empty>"            // no digits
      "</r>";
  auto root = ParseXml(doc);
  ASSERT_TRUE(root.ok()) << root.status();
  EXPECT_EQ(root->Child("ok")->text, "\xC3\xA9");
  EXPECT_EQ(root->Child("over")->text, "&#999999999999;");
  EXPECT_EQ(root->Child("surr")->text, "&#xD800;");
  EXPECT_EQ(root->Child("nul")->text, "&#0;");
  EXPECT_EQ(root->Child("bad")->text, "&#1g;");
  EXPECT_EQ(root->Child("empty")->text, "&#;");
}

TEST(Xml, FindDescendantWalksDepthFirst) {
  const std::string doc = "<a><b><c><target v='x'/></c></b></a>";
  auto root = ParseXml(doc);
  ASSERT_TRUE(root.ok());
  const XmlNode* t = root->FindDescendant("target");
  ASSERT_NE(t, nullptr);
  EXPECT_EQ(t->AttrOr("v", ""), "x");
}

TEST(Xml, RejectsMissingRoot) {
  EXPECT_FALSE(ParseXml("   <!-- only a comment -->  ").ok());
}

TEST(Xml, RejectsMismatchedEndTag) {
  // A closing tag that does not name the open element is mis-nesting,
  // not tolerated: accepting it would attach `<b>`'s content to `<a>`.
  auto root = ParseXml("<a><b>text</a></b>");
  ASSERT_FALSE(root.ok());
  EXPECT_NE(root.status().message().find("end tag"), std::string::npos)
      << root.status();
  // A prefixed end tag matches its unprefixed start tag and vice versa,
  // because names are compared after the namespace prefix is stripped.
  EXPECT_TRUE(ParseXml("<adm:a><b/></a>").ok());
  EXPECT_TRUE(ParseXml("<a><b/></adm:a>").ok());
}

}  // namespace
}  // namespace adm2iamf
