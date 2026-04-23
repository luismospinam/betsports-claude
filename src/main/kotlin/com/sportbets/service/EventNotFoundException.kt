package com.sportbets.service

class EventNotFoundException(url: String) : RuntimeException("Event not found (404): $url")
