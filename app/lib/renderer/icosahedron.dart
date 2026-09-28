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

import 'dart:math' as math;
import 'package:vector_math/vector_math.dart';

/// Subdivided icosahedron mesh on the unit sphere.
///
/// Used for soundfield visualization. Subdivision levels:
/// - 0: 12 vertices, 20 faces
/// - 1: 42 vertices, 80 faces
/// - 2: 162 vertices, 320 faces
/// - 3: 642 vertices, 1280 faces
/// - 4: 2562 vertices, 5120 faces
class Icosahedron {
  final List<Vector3> vertices;
  final List<(int, int, int)> faces;

  const Icosahedron._({required this.vertices, required this.faces});

  /// Generate a subdivided icosahedron at the given level.
  factory Icosahedron.generate({int subdivisions = 0}) {
    var vertices = _baseVertices();
    var faces = _baseFaces();

    for (var i = 0; i < subdivisions; i++) {
      final result = _subdivide(vertices, faces);
      vertices = result.$1;
      faces = result.$2;
    }

    return Icosahedron._(vertices: vertices, faces: faces);
  }

  /// Compute face centroids (normalized to unit sphere).
  List<Vector3> get centroids {
    return faces.map((f) {
      final c = (vertices[f.$1] + vertices[f.$2] + vertices[f.$3]) / 3.0;
      c.normalize();
      return c;
    }).toList();
  }

  /// Number of faces.
  int get faceCount => faces.length;

  /// Number of vertices.
  int get vertexCount => vertices.length;

  /// Euler characteristic check: V - E + F = 2.
  /// Edges = faces * 3 / 2 (each edge shared by 2 faces).
  bool get isValidTopology {
    final e = faces.length * 3 ~/ 2;
    return vertices.length - e + faces.length == 2;
  }

  // --- Base icosahedron (12 vertices, 20 faces) ---

  static List<Vector3> _baseVertices() {
    final phi = (1.0 + math.sqrt(5.0)) / 2.0; // golden ratio
    final verts = <Vector3>[
      Vector3(-1, phi, 0),
      Vector3(1, phi, 0),
      Vector3(-1, -phi, 0),
      Vector3(1, -phi, 0),
      Vector3(0, -1, phi),
      Vector3(0, 1, phi),
      Vector3(0, -1, -phi),
      Vector3(0, 1, -phi),
      Vector3(phi, 0, -1),
      Vector3(phi, 0, 1),
      Vector3(-phi, 0, -1),
      Vector3(-phi, 0, 1),
    ];
    // Normalize to unit sphere
    for (final v in verts) {
      v.normalize();
    }
    return verts;
  }

  static List<(int, int, int)> _baseFaces() {
    return const [
      (0, 11, 5),
      (0, 5, 1),
      (0, 1, 7),
      (0, 7, 10),
      (0, 10, 11),
      (1, 5, 9),
      (5, 11, 4),
      (11, 10, 2),
      (10, 7, 6),
      (7, 1, 8),
      (3, 9, 4),
      (3, 4, 2),
      (3, 2, 6),
      (3, 6, 8),
      (3, 8, 9),
      (4, 9, 5),
      (2, 4, 11),
      (6, 2, 10),
      (8, 6, 7),
      (9, 8, 1),
    ];
  }

  // --- Subdivision ---

  static (List<Vector3>, List<(int, int, int)>) _subdivide(
    List<Vector3> vertices,
    List<(int, int, int)> faces,
  ) {
    final newVerts = List<Vector3>.from(vertices);
    final midpointCache = <int, int>{};
    final newFaces = <(int, int, int)>[];

    int getMidpoint(int a, int b) {
      // Sorted key for edge deduplication
      final key = a < b ? a * 100000 + b : b * 100000 + a;
      if (midpointCache.containsKey(key)) return midpointCache[key]!;

      final mid = (newVerts[a] + newVerts[b]) / 2.0;
      mid.normalize();
      final idx = newVerts.length;
      newVerts.add(mid);
      midpointCache[key] = idx;
      return idx;
    }

    for (final (a, b, c) in faces) {
      final ab = getMidpoint(a, b);
      final bc = getMidpoint(b, c);
      final ca = getMidpoint(c, a);
      newFaces.add((a, ab, ca));
      newFaces.add((b, bc, ab));
      newFaces.add((c, ca, bc));
      newFaces.add((ab, bc, ca));
    }

    return (newVerts, newFaces);
  }
}
