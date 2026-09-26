/*
    2026 (c) Oleh, https://github.com/zm69

    Components shared by the serialization tests.
*/

package ode_ecs__serialization_tests

///////////////////////////////////////////////////////////////////////////////
// Components

    Position :: struct {
        x, y: int
    }

    AI :: struct {
        IQ: f32,
        neurons_count: int
    }

    Likes_Data :: struct {
        strength: int,
    }

    Ft_Status :: enum u8 {
        Alert,
        Armed,
        Wounded,
        Asleep,
    }
