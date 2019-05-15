//
//  ShareViewController.swift
//  AvatarSharingExtension
//
//  Created by Drew McCormack on 13/05/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import UIKit
import Social
import LLVS
import LLVSCloudKit
import CoreServices

class ShareViewController: UITableViewController {
    
    enum Error: Swift.Error {
        case userCancelled
    }
    
    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var saveButtonItem: UIBarButtonItem!
    
    var rootStoreDirectory: URL!
    var store: Store!
    var image: UIImage!
    
    var contactBook: ContactBook!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        saveButtonItem.isEnabled = false

        let docDir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.mentalfaculty.LoCo")!
        rootStoreDirectory = docDir.appendingPathComponent("ContactBook")
        store = try! Store(rootDirectoryURL: rootStoreDirectory)

        if let version = store.mostRecentHead?.identifier {
            contactBook = try! ContactBook(prevailingAt: version, loadingFrom: store)
        } else {
            contactBook = try! ContactBook(creatingIn: store)
        }

        loadImage()
    }

    func loadImage() {
        let item = extensionContext!.inputItems.first as! NSExtensionItem
        let provider = item.attachments!.first!
        if provider.hasItemConformingToTypeIdentifier(kUTTypeImage as String) {
            provider.loadItem(forTypeIdentifier: kUTTypeImage as String, options: nil) { item, error in
                guard error == nil else {
                    self.cancel(self)
                    return
                }
                
                if let image = item as? UIImage {
                    self.image = image
                } else if let url = item as? URL, url.isFileURL {
                    self.image = UIImage(contentsOfFile: url.path)
                } else {
                    self.cancel(self)
                    return
                }

                self.imageView.image = self.image
                self.saveButtonItem.isEnabled = true
            }
        } else {
            self.cancel(self)
        }
    }
    
    @IBAction func save(_ sender: Any) {
        var contact = contactBook.contacts[tableView.indexPathForSelectedRow!.row].value
        contact.avatarJPEGData = image.jpegData(compressionQuality: 0.8)
        try! contactBook.update(contact)
        extensionContext!.completeRequest(returningItems: nil, completionHandler: nil)
    }
    
    @IBAction func cancel(_ sender: Any) {
        extensionContext!.cancelRequest(withError: Error.userCancelled)
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return contactBook.contacts.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let contact = contactBook.contacts[indexPath.row].value
        let name = contact.person?.fullName ?? "Unnamed Contact"
        cell.textLabel!.text = "\(name)"
        return cell
    }
}
