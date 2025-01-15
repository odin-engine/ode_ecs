/*
    2025 (c) Oleh, https://github.com/zm69

    NOTE: Work In Progress (WIP)

    YOU CAN BUILD ANYTHING WITH ODE_ECS!
    The reason for this is that ecs.Table($T) itself can be a component or part of any copmonent.
    It means that you can build any data structure you want. 
*/

package ode_ecs_sample4

// Base
    import "base:runtime"

// Core
    import "core:fmt"
    import "core:log"
    import "core:slice"
    import "core:mem"
    import "core:math"
    import "core:math/rand"
    import "core:time"
    import "core:testing"
     
// ODE_ECS
    import ecs "../../"
    import oc "../../ode_core"

//
// Components
// 

    //
    // UI_Button
    //

        UI_Button :: struct {
            text: string,
        }

        ui_button__print :: proc(self: ^UI_Button) {
            fmt.print("button", self.text)
        }

    //
    // UI_Panel
    //

        UI_Panel :: struct { 
            color: int, 
            width: int,
            height: int, 
        }

        ui_panel__print :: proc(self: ^UI_Panel) {
            fmt.printf("panel width=%v height=%v", self.width, self.height)
        }

    //
    // UI_Text
    // 

        UI_Text :: struct {
            text: string
        }

        ui_text__print :: proc(self: ^UI_Text) {
            fmt.printf("text: %s ", self.text)
        }
    
    //
    // UI_Position
    //

        UI_Position :: struct {
            x, y: int,              // coordinates relative to parent Element
            parent: ^UI_Position, 
            children: ecs.Table(UI_Position),
        }

        ui_position__init :: proc (self: ^UI_Position, parent: ^UI_Position, x, y: int) {
            self.parent = parent
            self.x = x
            self.y = y
        }

        ui_position__add_child :: proc(self: ^UI_Position, db: ^ecs.Database, eid: ecs.entity_id) -> (child: ^UI_Position) {

            // lazy init
            if self.children.state == ecs.Object_State.Not_Initialized {
                err := ecs.table_init(&self.children, db, 10)
                if err != nil do report_error(err)
            }
        
            ecs.add_component(&self.children, eid)
        
            return nil
        }
        
        ui_position__print :: proc(root: ^UI_Position) {
        
        }
    
// 
// Globals
// 
    // ECS Database
    db: ecs.Database

//
// This example includes simple error handing.
//
main :: proc() {

    //
    // OPTIONAL: Setup memory tracking and logger. 
    //
        mem_track: oc.Mem_Track

        // Track memory leaks and bad frees
        context.allocator = oc.mem_track__init(&mem_track, context.allocator)  
        defer oc.mem_track__terminate(&mem_track)
        defer oc.mem_track__panic_if_bad_frees_or_leaks(&mem_track) // Defer statements are executed in the reverse order that they were declared

        // Log into console when panic happens
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        // Replace default allocator with panic allocator to make sure that  
        // no allocations happen outside of provided allocator
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

    //
    // Actual ODE_ECS sample starts here.
    //
        //
        // Simple error handling
        //
        err: ecs.Error
        
        root: UI_Position
    //
    // Init 
    //
        // Init database
        defer { 
            err = ecs.terminate(&db) 
            if err != nil do report_error(err)
        }
        err = ecs.init(&db, 100, allocator) 
        if err != nil { report_error(err); return }
        
        ui_position__init(&root, nil, 0, 0)

    //
    // Systems
    //


    //
    // Results
    //
        fmt.println("EEEEEEEEEEEEEE")

        //print_elements(&root)
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}



