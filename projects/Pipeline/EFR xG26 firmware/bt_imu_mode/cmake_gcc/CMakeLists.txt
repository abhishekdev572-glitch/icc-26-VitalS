# Define minimal required version of CMake.
cmake_minimum_required(VERSION "3.25")

# Project definition
project(
  bt_imu_mode
  VERSION 1.0
  LANGUAGES C CXX ASM
)

# Include the definition of the slc_bt_imu_mode target,
# which contains the content of the SLC project
include(bt_imu_mode.cmake)

# Main application target
add_executable(bt_imu_mode

  # Custom ML wrapper source.
  # CMakeLists.txt is inside cmake_gcc/, therefore ../ points
  # to the main bt_imu_mode project directory.
  ../pressure_risk_ml_xg26.cpp
)

target_include_directories(bt_imu_mode PUBLIC

  # Allow application/custom files in the project root
  # to find pressure_risk_ml_xg26.h.
  ${CMAKE_CURRENT_LIST_DIR}/..
)

target_compile_definitions(bt_imu_mode PUBLIC
  # Add additional macros here
)

target_compile_options(bt_imu_mode PUBLIC
  # Set additional compiler flags here
)

target_link_options(bt_imu_mode PUBLIC
  # Set additional linker flags here
)

# Link with the content defined in the SLC project
target_link_libraries(bt_imu_mode PRIVATE
  slc
)

# Include managed project content if available
include(bt_imu_mode_project.cmake OPTIONAL RESULT_VARIABLE managed_project)

if(managed_project)
  message(STATUS "Using managed project content from ${managed_project}")
endif()

# We now compile pressure_risk_ml_xg26.cpp.
# Use the C++ linker so the C++ ML/TFLite code is linked correctly.
set_target_properties(
  bt_imu_mode
  PROPERTIES
  LINKER_LANGUAGE CXX
)

# Create .bin, .hex and .s37 artifacts after building the project
add_custom_command(
  TARGET bt_imu_mode
  POST_BUILD

  COMMAND ${CMAKE_OBJCOPY}
          ${OBJCOPY_SREC_CMD}
          "$<TARGET_FILE:bt_imu_mode>"
          "$<TARGET_FILE_DIR:bt_imu_mode>/$<TARGET_FILE_BASE_NAME:bt_imu_mode>.s37"

  COMMAND ${CMAKE_OBJCOPY}
          ${OBJCOPY_IHEX_CMD}
          "$<TARGET_FILE:bt_imu_mode>"
          "$<TARGET_FILE_DIR:bt_imu_mode>/$<TARGET_FILE_BASE_NAME:bt_imu_mode>.hex"

  COMMAND ${CMAKE_OBJCOPY}
          ${OBJCOPY_BIN_CMD}
          "$<TARGET_FILE:bt_imu_mode>"
          "$<TARGET_FILE_DIR:bt_imu_mode>/$<TARGET_FILE_BASE_NAME:bt_imu_mode>.bin"
)

# Run post-build pipeline to perform additional post-processing
if(post_build_command)

  add_custom_command(
    TARGET bt_imu_mode
    POST_BUILD

    WORKING_DIRECTORY ${CMAKE_CURRENT_LIST_DIR}/..

    COMMAND ${post_build_command}
  )

endif()