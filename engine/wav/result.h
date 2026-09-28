/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//
// Minimal error-or-value types for the zero-dependency core. `Status` is an
// ok/error pair; `Result<T>` carries either a T or an error message. Both are
// deliberately tiny — consumers that live in an absl codebase can wrap them
// in StatusOr at the adapter layer.

#ifndef ECLIPSA_STUDIO_WAV_RESULT_H_
#define ECLIPSA_STUDIO_WAV_RESULT_H_

#include <cassert>
#include <optional>
#include <string>
#include <utility>

namespace wav {

class Status {
 public:
  // Default-constructed Status is OK.
  Status() = default;

  static Status Error(std::string message) {
    Status s;
    s.ok_ = false;
    s.message_ = std::move(message);
    return s;
  }

  bool ok() const { return ok_; }
  // Empty for an OK status.
  const std::string& message() const { return message_; }

 private:
  bool ok_ = true;
  std::string message_;
};

template <typename T>
class Result {
 public:
  // Implicit from a value: `return reader;`
  Result(T value) : value_(std::move(value)) {}  // NOLINT(runtime/explicit)

  // Implicit from a non-OK Status: `return Status::Error("...");`
  // Constructing from an OK status is a caller bug (there is no value to
  // hold); it still yields an error Result, with a diagnosable message
  // instead of a silent empty one.
  Result(Status status)  // NOLINT(runtime/explicit)
      : status_(std::move(status)) {
    if (status_.ok()) {
      status_ = Status::Error("Result constructed from an OK status.");
    }
  }

  static Result Error(std::string message) {
    return Result(Status::Error(std::move(message)));
  }

  bool ok() const { return value_.has_value(); }
  explicit operator bool() const { return ok(); }

  const Status& status() const { return status_; }
  // Empty when ok().
  const std::string& error() const { return status_.message(); }

  // Accessing the value of an error Result is a caller bug; the asserts
  // turn the silent optional UB into a debug-build diagnostic (absl's
  // StatusOr CHECKs here for the same reason).
  T& value() {
    assert(value_.has_value());
    return *value_;
  }
  const T& value() const {
    assert(value_.has_value());
    return *value_;
  }
  T* operator->() {
    assert(value_.has_value());
    return &*value_;
  }
  const T* operator->() const {
    assert(value_.has_value());
    return &*value_;
  }
  T& operator*() {
    assert(value_.has_value());
    return *value_;
  }
  const T& operator*() const {
    assert(value_.has_value());
    return *value_;
  }

 private:
  std::optional<T> value_;
  Status status_;
};

}  // namespace wav

#endif  // ECLIPSA_STUDIO_WAV_RESULT_H_
