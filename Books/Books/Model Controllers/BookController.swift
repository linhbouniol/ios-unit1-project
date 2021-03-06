//
//  BookController.swift
//  Books
//
//  Created by Linh Bouniol on 8/21/18.
//  Copyright © 2018 Linh Bouniol. All rights reserved.
//

import Foundation
import CoreData

class BookController {

    // MARK: - CRUD
    
    func createBook(with searchResult: SearchResult, inBookshelf bookshelf: Bookshelf) {
        
        // When searching for the same book that we already have, we don't want to create a new one in core data. So lets ask core data if it already has the book, and update it if it does.
        
        let identifier = searchResult.identifier
        
        var bookFromPersistentStore = self.fetchSingleBookFromPersistentStore(withID: identifier, context: CoreDataStack.shared.mainContext)
        
        if let book = bookFromPersistentStore {
            self.update(book: book, with: searchResult)
        } else {
            bookFromPersistentStore = Book(searchResult: searchResult)
        }
        
        guard let book = bookFromPersistentStore else { return }
        book.addToBookshelves(bookshelf)
        updateGoogleServerAdding(book: book, to: bookshelf)
        
        do {
            try CoreDataStack.shared.save()
        } catch {
            NSLog("Error creating book: \(error)")
        }
    }

    func move(book: Book, to bookshelf: Bookshelf, from oldBookshelf: Bookshelf? = nil) {
        if let oldBookshelf = oldBookshelf {
            book.removeFromBookshelves(oldBookshelf)
            updateGoogleServerRemoving(book: book, from: oldBookshelf)
        }
        
        // Mark book as read if we move it into the HaveRead bookshelf
        if bookshelf.identifier == 4 {
            book.hasRead = true
        }
        
        book.addToBookshelves(bookshelf)
        updateGoogleServerAdding(book: book, to: bookshelf)

        do {
            try CoreDataStack.shared.save()
        } catch {
            NSLog("Error moving book: \(error)")
        }
    }

    func toggleHasRead(for book: Book) {
        book.hasRead = !book.hasRead
        
        if let haveReadBookshelf = fetchSingleBookshelfFromPersistentStore(withID: 4, context: CoreDataStack.shared.mainContext) {
            
            if book.hasRead {
                // Add to HaveRead bookshelf on google server
                book.addToBookshelves(haveReadBookshelf)
                updateGoogleServerAdding(book: book, to: haveReadBookshelf)
            } else {
                // Remove from HaveRead. This function will remove it from bookshelf on device, remove it from google, and if book is not in any other bookshelves, delete from core data.
                delete(book: book, from: haveReadBookshelf)
            }
        }
        
        

        do {
            try CoreDataStack.shared.save()
        } catch {
            NSLog("Error updating book: \(error)")
        }
    }
    
    func update(book: Book, with review: String) {
        book.review = review
        
        do {
            try CoreDataStack.shared.save()
        } catch {
            NSLog("Error updating book review: \(error)")
        }
    }

    func delete(book: Book, from bookshelf: Bookshelf? = nil) {
        // Want to delete only from the bookshelf that we're current in..., only delete from core data if book is not part of any other bookshelves, or if bookshelf is nil
        
        if let bookshelf = bookshelf {
            book.removeFromBookshelves(bookshelf)
            updateGoogleServerRemoving(book: book, from: bookshelf)
        }
        
        if book.bookshelves?.count == 0 || bookshelf == nil {
            let moc = CoreDataStack.shared.mainContext
            moc.delete(book)
        }
        
//        let moc = CoreDataStack.shared.mainContext
//        moc.delete(book)
        
        do {
            try CoreDataStack.shared.save()
        } catch {
            NSLog("Error deleting book: \(error)")
        }
    }
    
    func createBookshelf(with name: String) {
        let _ = Bookshelf(name: name)
        
        do {
            try CoreDataStack.shared.save()
        } catch {
            NSLog("Error creating bookshelf: \(error)")
        }
    }

    func rename(bookshelf: Bookshelf, with newName: String) {
        bookshelf.name = newName

        do {
            try CoreDataStack.shared.save()
        } catch {
            NSLog("Error renaming bookshelf: \(error)")
        }
    }

    func delete(bookshelf: Bookshelf) {
        let moc = CoreDataStack.shared.mainContext
        moc.delete(bookshelf)
        
        do {
            try CoreDataStack.shared.save()
        } catch {
            NSLog("Error deleting bookshelf: \(error)")
        }
    }
    
    // MARK: - Google Books API
    
    // MARK: -- Fetch Bookshelves
    
    typealias CompletionHandler = (Error?) -> Void
    
    func fetchBookshelvesFromGoogleServer(completion: @escaping CompletionHandler = { _ in }) {
        
        let myBookshelvesURL = URL(string: "https://www.googleapis.com/books/v1/mylibrary/bookshelves")!
        
        var request = URLRequest(url: myBookshelvesURL)
        request.httpMethod = "GET"
        
        GoogleBooksAuthorizationClient.shared.addAuthorization(to: request) { (request, error) in
            if let error = error {
                NSLog("Error authorizing bookshelves: \(error)")
                DispatchQueue.main.async {
                    completion(error)
                }
                return
            }
            
            guard let request = request else {
                DispatchQueue.main.async {
                    completion(NSError())
                }
                return
            }
            
            URLSession.shared.dataTask(with: request, completionHandler: { (data, _, error) in
                if let error = error {
                    NSLog("Error loading bookshelves: \(error) ")
                    DispatchQueue.main.async {
                        completion(error)
                    }
                    return
                    
                }
                
                guard let data = data else {
                    DispatchQueue.main.async {
                        completion(NSError())
                    }
                    return
                }
                
                do {
                    let decodedBookshelves = try JSONDecoder().decode(BookshelvesRepresentation.self, from: data)
                    
                    let backgroundMOC = CoreDataStack.shared.container.newBackgroundContext()
                    
                    try self.updateBookshelves(with: decodedBookshelves.items, context: backgroundMOC)
                    
                    DispatchQueue.main.async {
                        completion(nil)
                    }

                } catch {
                    NSLog("Error decoding bookshelves: \(error)")
                    DispatchQueue.main.async {
                        completion(error)
                    }
                }
            }).resume()
        }
    }
    
    func fetchSingleBookshelfFromPersistentStore(withID id: Int, context: NSManagedObjectContext) -> Bookshelf? {
        
        let fetchRequest: NSFetchRequest<Bookshelf> = Bookshelf.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "identifier == %@", id as NSNumber)
        
        do {
            return try context.fetch(fetchRequest).first
        } catch {
            NSLog("Error fetching bookshelf with id \(id): \(error)")
            return nil
        }
    }
    
    func update(bookshelf: Bookshelf, with bookshelfRepresentation: BookshelfRepresentation) {
        bookshelf.name = bookshelfRepresentation.title
    }
    
    func updateBookshelves(with bookshelves: [BookshelfRepresentation], context: NSManagedObjectContext) throws {
        var error: Error?
        
        context.performAndWait {
            for bookshelfRepresentation in bookshelves {
                
                let id = bookshelfRepresentation.id
                
                let bookshelf = self.fetchSingleBookshelfFromPersistentStore(withID: id, context: context)
                
                if let bookshelf = bookshelf {
                    if bookshelf != bookshelfRepresentation {
                        self.update(bookshelf: bookshelf, with: bookshelfRepresentation)
                    }
                } else {
                    Bookshelf(bookshelfRepresentation: bookshelfRepresentation, context: context)
                }
            }
            
            do {
                try context.save()
            } catch let saveError {
                error = saveError
            }
        }
        
        if let error = error {
            throw error
        }
    }
    
    // MARK: -- Fetch Books
    
    func fetchBooksFromGoogleServer(in bookshelf: Bookshelf, completion: @escaping CompletionHandler = { _ in }) {
        guard let id = bookshelf.identifier as? Int else {
            completion(NSError())
            return
        }
        
        let myBookshelvesURL = URL(string: "https://www.googleapis.com/books/v1/mylibrary/bookshelves/\(id)/volumes")!
//        myBookshelvesURL.appendPathComponent(String(id), isDirectory: true)
//        myBookshelvesURL.appendPathComponent("volume", isDirectory: false)
        
        var request = URLRequest(url: myBookshelvesURL)
        request.httpMethod = "GET"
        
        GoogleBooksAuthorizationClient.shared.addAuthorization(to: request) { (request, error) in
            if let error = error {
                NSLog("Error authorizing books: \(error)")
                DispatchQueue.main.async {
                    completion(error)
                }
                return
            }
            
            guard let request = request else {
                DispatchQueue.main.async {
                    completion(NSError())
                }
                return
            }
            
            URLSession.shared.dataTask(with: request, completionHandler: { (data, _, error) in
                if let error = error {
                    NSLog("Error loading books: \(error) ")
                    DispatchQueue.main.async {
                        completion(error)
                    }
                    return
                }
                
                guard let data = data else {
                    DispatchQueue.main.async {
                        completion(NSError())
                    }
                    return
                }
                
                do {
                    // The API structure is identical to the searchResults so we're reusing it
                    let decodedBooks = try JSONDecoder().decode(SearchResults.self, from: data)
                    
                    let backgroundMOC = CoreDataStack.shared.container.newBackgroundContext()
                    
                    // Make sure the books are created within the context of the bookshelf we're loading
                    try self.updateBooks(with: decodedBooks.items, in: bookshelf, context: backgroundMOC)
                    
                    DispatchQueue.main.async {
                        completion(nil)
                    }
                    
                } catch {
                    NSLog("Error decoding books: \(error)")
                    DispatchQueue.main.async {
                        completion(error)
                    }
                }
            }).resume()
        }
    }
    
    func fetchSingleBookFromPersistentStore(withID identifier: String, context: NSManagedObjectContext) -> Book? {
        
        let fetchRequest: NSFetchRequest<Book> = Book.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "identifier == %@", identifier)
        
        do {
            return try context.fetch(fetchRequest).first
        } catch {
            NSLog("Error fetching book with id \(identifier): \(error)")
            return nil
        }
    }
    
    func update(book: Book, with searchResult: SearchResult) {
        book.title = searchResult.title
        book.authorsString = searchResult.authors?.joined(separator: ", ")
        book.imageURL = searchResult.image
        book.bookDescription = searchResult.descripton
        book.pages = searchResult.pages
        book.releasedDate = searchResult.releasedDate
    }
    
    func updateBooks(with books: [SearchResult], in bookshelf: Bookshelf, context: NSManagedObjectContext) throws {
        var error: Error?
        
        context.performAndWait {
            for bookRep in books {
                
                let identifier = bookRep.identifier
                
                let book = self.fetchSingleBookFromPersistentStore(withID: identifier, context: context)
                
                if let book = book {
                    self.update(book: book, with: bookRep)
                } else {
                    if let book = Book(searchResult: bookRep, context: context) {
                        book.addToBookshelves(bookshelf)
                    }
                }
            }
            
            do {
                try context.save()
            } catch let saveError {
                error = saveError
            }
        }
        
        if let error = error {
            throw error
        }
    }
    
    // MARK: -- Add Books to Bookshelf
    
    func updateGoogleServerAdding(book: Book, to bookshelf: Bookshelf, completion: @escaping CompletionHandler = { _ in }) {
        guard let bookshelfID = bookshelf.identifier as? Int, let bookID = book.identifier else {
            completion(NSError())
            return
        }
        
        let baseURL = URL(string: "https://www.googleapis.com/books/v1/mylibrary/bookshelves/\(bookshelfID)/addVolume")!
        
        var urlComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)!
        
        let volumeQueryItem = URLQueryItem(name: "volumeId", value: bookID)
        
        urlComponents.queryItems = [volumeQueryItem]
        
        // Check if url can be created using the components and deal with error
        guard let requestURL = urlComponents.url else {
            NSLog("Problem constructing addVolume URL for \(bookID)")
            completion(NSError())
            return
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        
        GoogleBooksAuthorizationClient.shared.addAuthorization(to: request) { (request, error) in
            if let error = error {
                NSLog("Error authorizing books: \(error)")
                DispatchQueue.main.async {
                    completion(error)
                }
                return
            }
            
            guard let request = request else {
                DispatchQueue.main.async {
                    completion(NSError())
                }
                return
            }
            
            URLSession.shared.dataTask(with: request, completionHandler: { (data, _, error) in
                if let error = error {
                    NSLog("Error adding book: \(error) ")
                    DispatchQueue.main.async {
                        completion(error)
                    }
                    return
                }
                
                DispatchQueue.main.async {
                    completion(nil)
                }
            }).resume()
        }
    }
    
    // MARK: -- Remove Books From Bookshelf
    
    func updateGoogleServerRemoving(book: Book, from bookshelf: Bookshelf, completion: @escaping CompletionHandler = { _ in }) {
        guard let bookshelfID = bookshelf.identifier as? Int, let bookID = book.identifier else {
            completion(NSError())
            return
        }
        
        let baseURL = URL(string: "https://www.googleapis.com/books/v1/mylibrary/bookshelves/\(bookshelfID)/removeVolume")!
        
        var urlComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)!
        
        let volumeQueryItem = URLQueryItem(name: "volumeId", value: bookID)
        
        urlComponents.queryItems = [volumeQueryItem]
        
        // Check if url can be created using the components and deal with error
        guard let requestURL = urlComponents.url else {
            NSLog("Problem constructing removeVolume URL for \(bookID)")
            completion(NSError())
            return
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        
        GoogleBooksAuthorizationClient.shared.addAuthorization(to: request) { (request, error) in
            if let error = error {
                NSLog("Error authorizing books: \(error)")
                DispatchQueue.main.async {
                    completion(error)
                }
                return
            }
            
            guard let request = request else {
                DispatchQueue.main.async {
                    completion(NSError())
                }
                return
            }
            
            URLSession.shared.dataTask(with: request, completionHandler: { (data, _, error) in
                if let error = error {
                    NSLog("Error removing book: \(error) ")
                    DispatchQueue.main.async {
                        completion(error)
                    }
                    return
                }
                
                DispatchQueue.main.async {
                    completion(nil)
                }
            }).resume()
        }
    }
}
