package com.sportbets

import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.runApplication
import org.springframework.scheduling.annotation.EnableScheduling

@SpringBootApplication
@EnableScheduling
class SportBetsApplication

fun main(args: Array<String>) {
    runApplication<SportBetsApplication>(*args)
}
