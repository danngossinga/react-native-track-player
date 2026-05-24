# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This fallback mirrors the shape of react-native-codegen output so Android New
# Architecture autolinking can link RNTrackPlayerSpec when app codegen does not
# generate library artifacts for this fork.

cmake_minimum_required(VERSION 3.13)
set(CMAKE_VERBOSE_MAKEFILE on)

file(GLOB react_codegen_SRCS CONFIGURE_DEPENDS *.cpp)

add_library(
  react_codegen_RNTrackPlayerSpec
  OBJECT
  ${react_codegen_SRCS}
)

target_include_directories(react_codegen_RNTrackPlayerSpec PUBLIC .)

target_link_libraries(
  react_codegen_RNTrackPlayerSpec
  fbjni
  jsi
  reactnative
)

target_compile_reactnative_options(react_codegen_RNTrackPlayerSpec PRIVATE)
