add_executable(clumpview WIN32
    main.cpp
)

target_link_libraries(clumpview
    PRIVATE
        librw::skeleton
        librw::librw
)

librw_platform_target(clumpview)
